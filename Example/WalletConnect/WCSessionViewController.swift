// Copyright © 2017-2019 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.

import UIKit
import WalletConnect
import PromiseKit
import TrustWalletCore
import UserNotifications

struct WalletsInfo {
  let name: String
  let universalLink: String
  let appCode: String
  let appStoreLink: String
}

func getWalletInfo() -> [WalletsInfo] {
  var wallets: [WalletsInfo] = []
  
  let metaMask = WalletsInfo(
    name: "MetaMask", universalLink: "https://metamask.app.link", appCode: "id1438144202", appStoreLink: "https://apps.apple.com/us/app/metamask/id1438144202")
  
  let trustWallet = WalletsInfo(name: "Trust Wallet", universalLink: "https://link.trustwallet.com", appCode: "id1288339409", appStoreLink: "https://apps.apple.com/app/apple-store/id1288339409")
  
  let safePal = WalletsInfo(name: "SafePal", universalLink: "https://link.safepal.io", appCode: "id1548297139", appStoreLink: "https://apps.apple.com/app/safepal-wallet/id1548297139")
  
  let rainBow = WalletsInfo(name: "Rainbow", universalLink: "https://rnbwapp.com", appCode: "id1457119021", appStoreLink: "https://apps.apple.com/us/app/rainbow-ethereum-wallet/id1457119021")
  
  
  wallets.append(metaMask)
  wallets.append(trustWallet)
  wallets.append(safePal)
  wallets.append(rainBow)
  
  return wallets
}

func checkAppInstalled(app: WalletsInfo) -> Bool {
  let url = app.universalLink
  let endPointURL = URL(string: url)!
  
  let appURLScheme = "\(app.name)://"
  
  guard let appURL = URL(string: appURLScheme) else { return false }
  
  if UIApplication.shared.canOpenURL(appURL) {
    return true
  }
  return false
}

class WCSessionViewController: UIViewController {
  
  @IBOutlet weak var uriField: UITextField!
  @IBOutlet weak var addressField: UITextField!
  @IBOutlet weak var chainIdField: UITextField!
  @IBOutlet weak var connectButton: UIButton!
  @IBOutlet weak var approveButton: UIButton!
  
  var interactor: WCInteractor?
  let clientMeta = WCPeerMeta(name: "WalletConnect SDK", url: "https://github.com/TrustWallet/wallet-connect-swift")
  
  let privateKey = PrivateKey(data: Data(hexString: "2537da353000cb7157f6b5333c62f5702a6d99a79184d3fad0b1708272496f83")!)!
  
  var string = ""
  var topic = ""
  
  var defaultAddress: String = ""
  var defaultChainId: Int = 1
  var recoverSession: Bool = false
  var notificationGranted: Bool = false
  
  private var backgroundTaskId: UIBackgroundTaskIdentifier?
  private weak var backgroundTimer: Timer?
  
  override func viewDidLoad() {
    super.viewDidLoad()
    
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { (granted, error) in
      print("<== notification permission: \(granted)")
      if let error = error {
        print(error)
      }
      self.notificationGranted = granted
    }
  }
  
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    
    let key = try! randomKey()
    topic = UUID().uuidString
    
    string = "wc:\(topic)@1?bridge=https%3A%2F%2Fs.bridge.walletconnect.org&key=\(key)"
    
    defaultAddress = CoinType.ethereum.deriveAddress(privateKey: privateKey)
    uriField.text = string
    addressField.text = defaultAddress
    chainIdField.text = "1"
    chainIdField.textAlignment = .center
    approveButton.isEnabled = false
    
  }
  
  // https://developer.apple.com/documentation/security/1399291-secrandomcopybytes
  private func randomKey() throws -> String {
    var bytes = [Int8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if status == errSecSuccess {
      return Data(bytes: bytes, count: 32).toHexString()
    } else {
      // we don't care in the example app
      enum TestError: Error {
        case unknown
      }
      throw TestError.unknown
    }
  }
  
  func connect(session: WCSession, wallet: WalletsInfo) {
    
    let interactor = WCInteractor(session: session, meta: clientMeta, uuid: UIDevice.current.identifierForVendor ?? UUID())
    
    configure(interactor: interactor)
    
    interactor.connect().done { [weak self] connected in
      guard let self = self else { return }
      
      if let webpageUrl = URL(string: "\(wallet.universalLink)/wc?uri=\(self.string)") {
        UIApplication.shared.open(webpageUrl)
      }
      
      self.connectionStatusUpdated(connected)
    }.catch { [weak self] error in
      self?.present(error: error)
    }
    
    self.interactor = interactor
  }
  
  func configure(interactor: WCInteractor) {
    let accounts = [defaultAddress]
    let chainId = defaultChainId
    
    interactor.onError = { [weak self] error in
      self?.present(error: error)
    }
    
    interactor.onSessionRequest = { [weak self] (id, peerParam) in
      let peer = peerParam.peerMeta
      let message = [peer.description, peer.url].joined(separator: "\n")
      let alert = UIAlertController(title: peer.name, message: message, preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "Reject", style: .destructive, handler: { _ in
        self?.interactor?.rejectSession().cauterize()
      }))
      alert.addAction(UIAlertAction(title: "Approve", style: .default, handler: { _ in
        self?.interactor?.approveSession(accounts: accounts, chainId: chainId).cauterize()
      }))
      self?.show(alert, sender: nil)
    }
    
    interactor.onDisconnect = { [weak self] (error) in
      if let error = error {
        print(error)
      }
      self?.connectionStatusUpdated(false)
    }
    
    interactor.eth.onSign = { [weak self] (id, payload) in
      let alert = UIAlertController(title: payload.method, message: payload.message, preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "Cancel", style: .destructive, handler: { _ in
        self?.interactor?.rejectRequest(id: id, message: "User canceled").cauterize()
      }))
      alert.addAction(UIAlertAction(title: "Sign", style: .default, handler: { _ in
        self?.signEth(id: id, payload: payload)
      }))
      self?.show(alert, sender: nil)
    }
    
    interactor.eth.onTransaction = { [weak self] (id, event, transaction) in
      let data = try! JSONEncoder().encode(transaction)
      let message = String(data: data, encoding: .utf8)
      let alert = UIAlertController(title: event.rawValue, message: message, preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "Reject", style: .destructive, handler: { _ in
        self?.interactor?.rejectRequest(id: id, message: "I don't have ethers").cauterize()
      }))
      self?.show(alert, sender: nil)
    }
    
    interactor.bnb.onSign = { [weak self] (id, order) in
      let message = order.encodedString
      let alert = UIAlertController(title: "bnb_sign", message: message, preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "Cancel", style: .destructive, handler: { [weak self] _ in
        self?.interactor?.rejectRequest(id: id, message: "User canceled").cauterize()
      }))
      alert.addAction(UIAlertAction(title: "Sign", style: .default, handler: { [weak self] _ in
        self?.signBnbOrder(id: id, order: order)
      }))
      self?.show(alert, sender: nil)
    }
    
    interactor.okt.onTransaction = { [weak self] (id, event, transaction) in
      let data = try! JSONEncoder().encode(transaction)
      let message = String(data: data, encoding: .utf8)
      let alert = UIAlertController(title: event.rawValue, message: message, preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "Reject", style: .destructive, handler: { _ in
        self?.interactor?.rejectRequest(id: id, message: "I don't have ok").cauterize()
      }))
      alert.addAction(UIAlertAction(title: "Approve", style: .default, handler: { (_) in
        self?.interactor?.approveRequest(id: id, result: "This is the signed data").cauterize()
      }))
      self?.show(alert, sender: nil)
    }
  }
  
  func approve(accounts: [String], chainId: Int) {
    interactor?.approveSession(accounts: accounts, chainId: chainId).done {
      print("<== approveSession done")
    }.catch { [weak self] error in
      self?.present(error: error)
    }
  }
  
  func signEth(id: Int64, payload: WCEthereumSignPayload) {
    let data: Data = {
      switch payload {
        case .sign(let data, _):
          return data
        case .personalSign(let data, _):
          let prefix = "\u{19}Ethereum Signed Message:\n\(data)".data(using: .utf8)!
          return prefix + data
        case .signTypeData(_, let data, _):
          // FIXME
          return data
      }
    }()
    
    var result = privateKey.sign(digest: Hash.keccak256(data: data), curve: .secp256k1)!
    result[64] += 27
    self.interactor?.approveRequest(id: id, result: "0x" + result.hexString).cauterize()
  }
  
  func signBnbOrder(id: Int64, order: WCBinanceOrder) {
    let data = order.encoded
    print("==> signbnbOrder", String(data: data, encoding: .utf8)!)
    let signature = privateKey.sign(digest: Hash.sha256(data: data), curve: .secp256k1)!
    let signed = WCBinanceOrderSignature(
      signature: signature.dropLast().hexString,
      publicKey: privateKey.getPublicKeySecp256k1(compressed: false).data.hexString
    )
    interactor?.approveBnbOrder(id: id, signed: signed).done({ confirm in
      print("<== approveBnbOrder", confirm)
    }).catch { [weak self] error in
      self?.present(error: error)
    }
  }
  
  func connectionStatusUpdated(_ connected: Bool) {
    self.approveButton.isEnabled = connected
    self.connectButton.setTitle(!connected ? "Connect" : "Kill Session", for: .normal)
  }
  
  func present(error: Error) {
    let alert = UIAlertController(title: "Error", message: error.localizedDescription, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
    self.show(alert, sender: nil)
  }
  
  @IBAction func connectTapped() {
    guard let string = uriField.text, let session = WCSession.from(string: string) else {
      print("invalid uri: \(String(describing: uriField.text))")
      return
    }
    if let i = interactor, i.state == .connected {
      i.killSession().done {  [weak self] in
        self?.approveButton.isEnabled = false
        self?.connectButton.setTitle("Connect", for: .normal)
      }.cauterize()
    } else {
      showActionSheet(session)
    }
  }
  
  func showActionSheet(_ session: WCSession) {
    let wallets: [WalletsInfo] = getWalletInfo()
    
    let alert = UIAlertController(title: "Select wallet",
                                  message: nil,
                                  preferredStyle: .actionSheet)
    
    for wallet in wallets {
      let action = UIAlertAction(title: wallet.name,
                                 style: .default) { [weak self] action in
        guard let self = self else { return }
        
        self.connect(session: session, wallet: wallet)
      }
      
      alert.addAction(action)
    }
    let cancel = UIAlertAction(title: "Cancel",
                               style: .cancel)
    alert.addAction(cancel)
    
    present(alert, animated: true)
    
  }
  
  @IBAction func approveTapped() {
    guard let address = addressField.text,
          let chainIdString = chainIdField.text else {
            print("empty address or chainId")
            return
          }
    guard let chainId = Int(chainIdString) else {
      print("invalid chainId")
      return
    }
    guard EthereumAddress.isValidString(string: address) || CosmosAddress.isValidString(string: address) else {
      print("invalid eth or bnb address")
      return
    }
    approve(accounts: [address], chainId: chainId)
  }
}

extension WCSessionViewController {
  func applicationDidEnterBackground(_ application: UIApplication) {
    print("<== applicationDidEnterBackground")
    
    if interactor?.state != .connected {
      return
    }
    
    if notificationGranted {
      pauseInteractor()
    } else {
      startBackgroundTask(application)
    }
  }
  
  func applicationWillEnterForeground(_ application: UIApplication) {
    print("==> applicationWillEnterForeground")
    if let id = backgroundTaskId {
      application.endBackgroundTask(id)
    }
    backgroundTimer?.invalidate()
    
    if recoverSession {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) {
        self.interactor?.resume()
      }
    }
  }
  
  func startBackgroundTask(_ application: UIApplication) {
    backgroundTaskId = application.beginBackgroundTask(withName: "WalletConnect", expirationHandler: {
      self.backgroundTimer?.invalidate()
      print("<== background task expired")
    })
    
    var alerted = false
    backgroundTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
      print("<== background time remainning: ", application.backgroundTimeRemaining)
      if application.backgroundTimeRemaining < 15 {
        self.pauseInteractor()
      } else if application.backgroundTimeRemaining < 120 && !alerted {
        let notification = self.createWarningNotification()
        UNUserNotificationCenter.current().add(notification, withCompletionHandler: { error in
          alerted = true
          if let error = error {
            print("post error \(error.localizedDescription)")
          }
        })
      }
    }
  }
  
  func pauseInteractor() {
    recoverSession = true
    interactor?.pause()
  }
  
  func createWarningNotification() -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.title = "WC session will be interrupted"
    content.sound = UNNotificationSound.default
    
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
    
    return UNNotificationRequest(identifier: "session.warning", content: content, trigger: trigger)
  }
}
