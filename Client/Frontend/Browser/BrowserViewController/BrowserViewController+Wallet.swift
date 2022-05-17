// Copyright 2021 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import BraveWallet
import struct Shared.InternalURL
import struct Shared.Logger
import BraveCore
import SwiftUI
import BraveUI
import Data
import BraveShared

private let log = Logger.browserLogger

extension WalletStore {
  /// Creates a WalletStore based on whether or not the user is in Private Mode
  static func from(privateMode: Bool) -> WalletStore? {
    guard
      let keyringService = BraveWallet.KeyringServiceFactory.get(privateMode: privateMode),
      let rpcService = BraveWallet.JsonRpcServiceFactory.get(privateMode: privateMode),
      let assetRatioService = BraveWallet.AssetRatioServiceFactory.get(privateMode: privateMode),
      let walletService = BraveWallet.ServiceFactory.get(privateMode: privateMode),
      let swapService = BraveWallet.SwapServiceFactory.get(privateMode: privateMode),
      let txService = BraveWallet.TxServiceFactory.get(privateMode: privateMode),
      let ethTxManagerProxy = BraveWallet.EthTxManagerProxyFactory.get(privateMode: privateMode)
    else {
      log.error("Failed to load wallet. One or more services were unavailable")
      return nil
    }
    return WalletStore(
      keyringService: keyringService,
      rpcService: rpcService,
      walletService: walletService,
      assetRatioService: assetRatioService,
      swapService: swapService,
      blockchainRegistry: BraveCoreMain.blockchainRegistry,
      txService: txService,
      ethTxManagerProxy: ethTxManagerProxy
    )
  }
}

extension BrowserViewController {
  func presentWalletPanel() {
    let privateMode = PrivateBrowsingManager.shared.isPrivateBrowsing
    guard let walletStore = WalletStore.from(privateMode: privateMode) else {
      return
    }
    let controller = WalletPanelHostingController(
      walletStore: walletStore,
      origin: getOrigin(),
      faviconRenderer: FavIconImageRenderer()
    )
    controller.delegate = self
    let popover = PopoverController(contentController: controller, contentSizeBehavior: .autoLayout)
    popover.present(from: topToolbar.locationView.walletButton, on: self, completion: nil)
    scrollController.showToolbars(animated: true)
  }
}

extension WalletPanelHostingController: PopoverContentComponent {}

extension BrowserViewController: BraveWalletDelegate {
  func openWalletURL(_ destinationURL: URL) {
    if presentedViewController != nil {
      // dismiss to show the new tab
      self.dismiss(animated: true)
    }
    if let url = tabManager.selectedTab?.url, InternalURL.isValid(url: url) {
      select(url: destinationURL, visitType: .link)
    } else {
      _ = tabManager.addTabAndSelect(
        URLRequest(url: destinationURL),
        isPrivate: PrivateBrowsingManager.shared.isPrivateBrowsing
      )
    }
  }
}

extension BrowserViewController: BraveWalletProviderDelegate {
  func showPanel() {
    // TODO: Show ad-like notification prompt before calling `presentWalletPanel`
    presentWalletPanel()
  }

  func getOrigin() -> URLOrigin {
    guard let origin = tabManager.selectedTab?.url?.origin else {
      assert(false, "We should have a valid origin to get to this point")
      return .init()
    }
    return origin
  }

  func requestPermissions(_ type: BraveWallet.CoinType, accounts: [String], completion: @escaping RequestPermissionsCallback) {
    Task { @MainActor in
      let permissionRequestManager = WalletProviderPermissionRequestsManager.shared
      let origin = getOrigin()
      
      if permissionRequestManager.hasPendingRequest(for: origin, coinType: type) {
        completion(.requestInProgress, nil)
        return
      }
      
      let isPrivate = PrivateBrowsingManager.shared.isPrivateBrowsing
      
      // Check if eth permissions already exist for this origin and if they don't, ensure the user allows
      // ethereum provider access
      let ethPermissions = origin.url.map { Domain.ethereumPermissions(forUrl: $0) ?? [] } ?? []
      if ethPermissions.isEmpty, !Preferences.Wallet.allowEthereumProviderAccountRequests.value {
        completion(.internal, nil)
        return
      }
      
      guard let walletStore = WalletStore.from(privateMode: isPrivate) else {
        completion(.internal, nil)
        return
      }
      let (success, accounts) = await allowedAccounts(type, accounts: accounts)
      if !success {
        completion(.internal, [])
        return
      }
      if success && !accounts.isEmpty {
        completion(.none, accounts)
        return
      }
      
      let request = permissionRequestManager.beginRequest(for: origin, coinType: .eth, completion: { response in
        switch response {
        case .granted(let accounts):
          completion(.none, accounts)
        case .rejected:
          completion(.none, [])
        }
      })
      let permissions = WalletHostingViewController(
        walletStore: walletStore,
        presentingContext: .requestEthererumPermissions(request),
        faviconRenderer: FavIconImageRenderer(),
        onUnlock: {
          Task { @MainActor in
            // If the user unlocks their wallet and we already have permissions setup they do not
            // go through the regular flow
            let (success, accounts) = await self.allowedAccounts(type, accounts: accounts)
            if success, !accounts.isEmpty {
              permissionRequestManager.cancelRequest(request)
              completion(.none, accounts)
              self.dismiss(animated: true)
              return
            }
          }
        }
      )
      permissions.delegate = self
      present(permissions, animated: true)
    }
  }

  func allowedAccounts(_ type: BraveWallet.CoinType, accounts: [String]) async -> (Bool, [String]) {
    guard let selectedTab = tabManager.selectedTab else {
      return (false, [])
    }
    updateURLBarWalletButton()
    return await selectedTab.allowedAccounts(type, accounts: accounts)
  }
  
  func isAccountAllowed(_ type: BraveWallet.CoinType, account: String) async -> Bool {
    guard let selectedTab = tabManager.selectedTab else {
      return false
    }
    return await selectedTab.allowedAccounts(type, accounts: [account]).1.contains(account)
  }

  func updateURLBarWalletButton() {
    topToolbar.locationView.walletButton.buttonState =
    tabManager.selectedTab?.isWalletIconVisible == true ? .active : .inactive
  }
  
  func walletInteractionDetected() {
    // No usage for iOS
  }
  
  func showWalletOnboarding() {
    // No usage for iOS
  }
}

extension Tab: BraveWalletEventsListener {
  func emitEthereumEvent(_ event: Web3ProviderEvent) {
    var arguments: [Any] = [event.name]
    if let eventArgs = event.arguments {
      arguments.append(eventArgs)
    }
    webView?.evaluateSafeJavaScript(
      functionName: "window.ethereum.emit",
      args: arguments,
      contentWorld: .page,
      completion: nil
    )
  }
  
  func chainChangedEvent(_ chainId: String) {
    Task { @MainActor in
      guard let provider = walletProvider,
            case let currentChainId = await provider.chainId(),
            chainId != currentChainId else { return }
      emitEthereumEvent(.ethereumChainChanged(chainId: chainId))
      updateEthereumProperties()
    }
  }
  
  func accountsChangedEvent(_ accounts: [String]) {
    emitEthereumEvent(.ethereumAccountsChanged(accounts: accounts))
    updateEthereumProperties()
  }

  @MainActor func allowedAccounts(_ type: BraveWallet.CoinType, accounts: [String]) async -> (Bool, [String]) {
    func filterAccounts(
      _ accounts: [String],
      selectedAccount: String?
    ) -> [String] {
      if let selectedAccount = selectedAccount, accounts.contains(selectedAccount) {
        return [selectedAccount]
      }
      return accounts
    }
    // This method is called immediately upon creation of the wallet provider, which happens at tab
    // configuration, which means it may not be selected or ready yet.
    guard let keyringService = BraveWallet.KeyringServiceFactory.get(privateMode: false),
          let originURL = url?.origin.url else {
      return (false, [])
    }
    let isLocked = await keyringService.isLocked()
    if isLocked {
      return (false, [])
    }
    let selectedAccount = await keyringService.selectedAccount(type)
    let permissions: [String]? = {
      switch type {
      case .eth:
        return Domain.ethereumPermissions(forUrl: originURL)
      case .sol, .fil:
        return nil
      @unknown default:
        return nil
      }
    }()
    return (
      true,
      filterAccounts(permissions ?? [], selectedAccount: selectedAccount)
    )
  }
  
  func updateEthereumProperties() {
    guard let keyringService = BraveWallet.KeyringServiceFactory.get(privateMode: false),
          let walletService = BraveWallet.ServiceFactory.get(privateMode: false) else {
      return
    }
    Task { @MainActor in
      /// Turn an optional value into a string (or quoted string in case of the value being a string) or
      /// return `undefined`
      func valueOrUndefined<T>(_ value: T?) -> String {
        switch value {
        case .some(let string as String):
          return "\"\(string)\""
        case .some(let value):
          return "\(value)"
        case .none:
          return "undefined"
        }
      }
      guard let webView = webView, let provider = walletProvider else {
        return
      }
      let chainId = await provider.chainId()
      webView.evaluateSafeJavaScript(
        functionName: "window.ethereum.chainId = \"\(chainId)\"",
        contentWorld: .page,
        asFunction: false,
        completion: nil
      )
      let networkVersion = valueOrUndefined(Int(chainId.removingHexPrefix, radix: 16))
      webView.evaluateSafeJavaScript(
        functionName: "window.ethereum.networkVersion = \(networkVersion)",
        contentWorld: .page,
        asFunction: false,
        completion: nil
      )
      let coin = await walletService.selectedCoin()
      let accounts = await keyringService.keyringInfo(coin.keyringId).accountInfos.map(\.address)
      let selectedAccount = valueOrUndefined(await allowedAccounts(coin, accounts: accounts).1.first)
      webView.evaluateSafeJavaScript(
        functionName: "window.ethereum.selectedAddress = \(selectedAccount)",
        contentWorld: .page,
        asFunction: false,
        completion: nil
      )
    }
  }
}

extension BraveWallet.CoinType {
  var keyringId: String {
    switch self {
    case .eth:
      return BraveWallet.DefaultKeyringId
    case .sol:
      return BraveWallet.SolanaKeyringId
    case .fil:
      return BraveWallet.FilecoinKeyringId
    @unknown default:
      return ""
    }
  }
}

extension Tab: BraveWalletKeyringServiceObserver {
  func keyringCreated(_ keyringId: String) {
  }
  
  func keyringRestored(_ keyringId: String) {
  }
  
  func keyringReset() {
    reload()
  }
  
  func locked() {
  }
  
  func unlocked() {
  }
  
  func backedUp() {
  }
  
  func accountsChanged() {
  }
  
  func autoLockMinutesChanged() {
  }
  
  func selectedAccountChanged(_ coin: BraveWallet.CoinType) {
  }
}

extension FavIconImageRenderer: WalletFaviconRenderer {
  func loadIcon(siteURL: URL, persistent: Bool, completion: ((UIImage?) -> Void)?) {
    loadIcon(siteURL: siteURL, kind: .largeIcon, persistent: persistent, completion: completion)
  }
}
