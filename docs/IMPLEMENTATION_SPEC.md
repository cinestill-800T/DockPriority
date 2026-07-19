# DockPriority 0.1.0 実装仕様書

## 1. 目的と完成条件

DockPriority は、macOS が「現在アクティブ」と報告するディスプレイのうち、
ユーザーが保存した優先順位で最上位の画面を Dock の表示先として選び続ける。
解像度・HDR・配置変更や接続切替によって Dock が別画面へ移動しても、保護中は
正しい表示先へ戻す。KVM 等を macOS が検知できない場合は、保存順位を変えずに
接続中の画面へ一時切替できる。

0.1.0 の完成条件は次のすべてである。

- プロファイルを完全に廃止し、保存される優先順位を一つにする。
- 接続中の最上位画面へのフォールバックと、上位画面復帰時の自動復帰が動く。
- 接続中画面への一時切替と「優先順位に戻す」がメイン画面とメニューバーから
  1クリックで実行でき、保存順位を書き換えない。
- ディスプレイ通知と保護中5秒周期の監視の双方で誤配置を修復する。
- 本書の自動テスト、実機試験、配布ゲートを満たす。

「絶対に指定画面へ表示する」とは、公開APIで画面がアクティブと判定でき、
Accessibility 権限があり、Dock が応答する限り、常に本仕様の選択結果を使用して
誤配置を再試行することを意味する。EDIDをエミュレートするKVMなど、macOS自体が
切断を報告しないケースを推測で判定しない。その場合は一時切替を使用する。

## 2. ユーザー向け仕様

### 2.1 優先順位

- 過去に一度でも検出した画面を、接続中・未接続にかかわらず一つの順序付き一覧に
  保存する。プロファイル、既定アンカー、プロファイル自動切替は存在しない。
- 保存一覧が空の初回起動では、現在のメイン画面を先頭にし、残りを画面フレームの
  `minX`、`minY`、最後に識別子文字列の昇順で追加する。
- 以後に初検出した画面は必ず末尾へ追加する。既存項目の順位を自動変更しない。
- ユーザーはドラッグ操作または上下ボタンで全項目を並べ替えられる。未接続項目も
  並べ替え可能とし、0.1.0では項目削除機能を設けない。
- 通常の目標画面は、保存一覧を先頭から見て最初にアクティブな画面である。上位画面が
  切断されれば次順位へ移り、復帰すれば上位へ自動的に戻る。
- アクティブ画面が一つもない場合は移動せず `利用可能なディスプレイなし` と表示する。
  新しいアクティブ画面を検出した時点で通常選択を再開する。

### 2.2 一時切替

- メイン画面とメニューバーの「一時的に表示」一覧には、現在アクティブな画面だけを
  表示する。選択は即時に一時目標を設定し、優先順位を変更しない。
- 一時目標がある間の実効目標は一時目標であり、保護中のイベント監視と5秒監視も
  その画面を維持する。通常の第1順位へ勝手に引き戻さない。
- `優先順位に戻す` は一時目標を消去し、その時点の通常目標へ即時移動を1回試みる。
- 一時目標は永続化しない。アプリ再起動時は必ず通常順位から開始する。
- 次のいずれかを観測した時点で、一時目標を即時解除する: 画面の接続/切断、解像度、
  リフレッシュレート、スケーリング、HDR、配置、ミラーリング、メイン画面の変更、
  システムのスリープ、復帰、画面ロック解除後の再構成。
- 一時目標の画面が利用不能になった場合も同じイベント処理で解除し、通常目標へ
  フォールバックする。通知を出さないKVM切替では一時目標を維持する。
- 保護停止中でも画面の一時選択と `優先順位に戻す` は、その瞬間だけDock移動を1回
  試みる。その後は自動修復しない。一時選択状態自体は、上記解除条件まで保持する。

### 2.3 保護状態

- `保護を開始` はマウスイベント抑止、ディスプレイ通知監視、目標再評価を有効にし、
  現在の実効目標へ即時移動を試みた後、5秒周期の watchdog を開始する。
- `保護を停止` はイベントタップとwatchdogを停止する。保存順位と一時目標は変更しない。
  ディスプレイ/電源通知の購読は継続し、一覧更新と一時目標解除は行うが、自動移動はしない。
- watchdog は保護中だけ稼働する。各tickでインベントリを更新し、実効目標を再計算し、
  Dockの所在が異なる時または所在を判定できない時だけ移動を試みる。周期は5.0秒、
  toleranceは0.5秒とする。停止時・アプリ終了時は必ず無効化する。
- 順位変更時、一時目標がなければ保護中は新しい通常目標へ即時移動する。一時目標が
  ある場合はそれを維持し、順位変更は後の通常選択にだけ反映する。停止中は順位変更だけで
  Dockを移動しない。

## 3. データモデルと永続化

### 3.1 画面識別

実装する値型は次の責務を持つ。名称は原則としてこのまま使用する。

```swift
struct EDIDDisplayKey: Codable, Hashable, Sendable {
    let vendorID: UInt32
    let productID: UInt32
    let serialNumber: UInt32
}

enum DisplayIdentity: Codable, Hashable, Sendable {
    case edid(EDIDDisplayKey)
    case cgUUID(String)
}

struct DisplaySnapshot: Identifiable, Equatable, Sendable {
    let runtimeID: CGDirectDisplayID
    let identity: DisplayIdentity
    let name: String
    let frame: CGRect
    let isMain: Bool
    let isBuiltIn: Bool
    let modeSignature: DisplayModeSignature
    var id: DisplayIdentity { identity }
}

struct RememberedDisplay: Codable, Equatable, Identifiable, Sendable {
    let identity: DisplayIdentity
    var lastKnownName: String
    var id: DisplayIdentity { identity }
}

struct StoredPriorityState: Codable, Equatable, Sendable {
    let schemaVersion: Int       // 1
    var orderedDisplays: [RememberedDisplay]
}
```

識別子は `CGDisplayVendorNumber`、`CGDisplayModelNumber` と EDID/IOKit から得た
非ゼロの物理シリアルがすべて有効なら `.edid` を使用する。シリアルが0・欠落・取得失敗
なら `CGDisplayCreateUUIDFromDisplayID` の文字列を `.cgUUID` として使う。UUIDも取得
できない画面はその更新サイクルでは管理対象外とし、ログへ記録する。名前、接続順、
`CGDirectDisplayID` は永続識別に使わない。同一EDIDキーが同時に重複した場合は衝突として
両方をCG UUIDへ降格し、別画面として扱う。

`DisplayModeSignature` は少なくともピクセル幅/高さ、論理解像度、リフレッシュレート、
フレーム、回転、メイン/ミラー状態を含める。HDR値を公開APIで取得できる場合は含めるが、
HDR検知の必須経路は再構成コールバックであり、私有APIは使用しない。

### 3.2 保存規則

- `DisplayPriorityStore` が `UserDefaults` の単一キー `displayPriority.state.v1` に
  `StoredPriorityState` のJSON `Data` を保存する。書込みは順位/名称/新規検出の変更時だけ。
- 読込み後は識別子重複を最初の項目だけ残して正規化し、検出済み画面の名称を更新する。
- デコード失敗時はエラーを `Logger` へ残し、空状態として現在画面から再構築する。
  起動を失敗させない。
- DockAnchor の bundle、UserDefaults、Core Data、プロファイル、選択画面を探索・移行・削除
  しない。新しいbundle IDにより完全に独立して開始する。
- 一時目標、実行時ID、現在のアクティブ一覧、Dock所在、保護状態は保存しない。

## 4. アーキテクチャと制御フロー

### 4.1 必須のテスト境界

```swift
protocol DisplayInventory {
    func activeDisplays() throws -> [DisplaySnapshot]
    func startObserving(_ handler: @escaping @Sendable (DisplayChangeReason) -> Void)
    func stopObserving()
}

protocol DockLocating {
    func dockDisplay(in displays: [DisplaySnapshot]) async throws -> DisplayIdentity?
}

protocol DockRelocating {
    func relocate(to display: DisplaySnapshot) async throws
}

protocol DisplayPriorityStoring {
    func load() throws -> StoredPriorityState?
    func save(_ state: StoredPriorityState) throws
}

protocol WatchdogScheduling {
    func start(interval: Duration, tick: @escaping @Sendable () -> Void)
    func stop()
}
```

本番実装は `SystemDisplayInventory`、`AccessibilityDockLocator`、
`CGEventDockRelocator`、`UserDefaultsDisplayPriorityStore`、`TimerWatchdogScheduler` とする。
UIやcoordinatorから `NSScreen`、AX、CGEvent、UserDefaults、Timerを直接呼ばない。

`SystemDisplayInventory` は `CGGetActiveDisplayList` の結果のうち、online/activeでsleep中では
ない画面だけを返す。`CGDisplayRegisterReconfigurationCallback`、
`NSApplication.didChangeScreenParametersNotification`、workspaceのsleep/wake通知、画面unlock
通知を購読する。再構成開始では即座に理由を通知し、連続イベントは750ms debounceして
再取得する。wakeは2秒後に再取得し、保護中ならwatchdogが以後の遅延復帰も回収する。

Dock所在は Dock プロセスのAccessibility window/frameを公開AX APIで読み、中心点を含む
`DisplaySnapshot.frame` から判定する。取得不能は `nil` ではなく理由付きエラーにし、権限不足と
一時的なDock不在を区別する。移動は公開CGEvent APIで対象画面のDock edgeへマウス圧を生成する
既存方式を封じ込める。Dock kill、私有CoreGraphics/CGS API、shell、AppleScriptは使用しない。
移動前の実カーソル位置を保存し、完了/失敗/キャンセルの全経路で復元する。

### 4.2 Coordinator

`@MainActor final class DockPriorityCoordinator: ObservableObject` を唯一の方針決定者とする。
公開状態は `rememberedDisplays`、`activeDisplays`、`protectionState`、`temporaryTarget`、
`effectiveTarget`、`dockLocation`、`status`。公開操作は `startProtection()`、
`stopProtection()`、`movePriority(fromOffsets:toOffset:)`、`movePriorityUp(_:)`、
`movePriorityDown(_:)`、`selectTemporaryTarget(_:)`、`returnToPriority()`、`refresh()` とする。

すべてのイベントをMainActorへ戻して直列処理する。coordinatorは `generation: UInt64` を持ち、
ディスプレイイベント、一時選択/解除、保護開始/停止、順位変更ごとにincrementする。非同期の
所在確認・移動は開始時のgenerationと目標identityをcaptureし、実行直前と結果反映前に現在値と
一致することを確認する。不一致なら結果を破棄し、古い画面への移動を開始しない。新しい要求は
保留Taskをcancelし、同時移動は常に一つに制限する。

reconcileの順序は固定する。

1. inventoryを取得し、保存一覧へ新規画面を末尾追加、既存名称を更新して必要時だけ保存する。
2. イベント理由が一時目標解除条件なら、一時目標を消す。
3. 一時目標がアクティブならそれを、なければ保存順位の最初のアクティブ画面を実効目標にする。
4. 保護停止中の自動reconcileは状態更新だけで終了する。明示操作からのone-shotは続行する。
5. Dock所在を取得し、目標と同一なら成功として終了する。異なる/不明なら一度移動する。
6. 移動後に所在を再取得して確認する。失敗はstatusとLoggerへ残すが、保存順位を変えない。
   保護中は次の5秒tickで再試行し、UIをブロックする同期ループは行わない。

### 4.3 権限とエラー

- Accessibility未許可では保護開始/one-shot移動を失敗状態にし、System Settingsを開くボタンを
  表示する。自動プロンプトを5秒ごとに繰り返さない。順位編集とインベントリ表示は利用可能。
- store保存失敗は現在セッションの順位を維持し、永続化失敗を表示/記録する。順位を元へ戻さない。
- inventory取得失敗時は直前の保存順位を保持し、アクティブ一覧だけ空として次イベント/tickを待つ。
- relocation失敗は一時目標を解除しない。ユーザーの選択を維持し、再試行または明示解除を可能にする。
- ログは `Logger` の subsystem をbundle ID、categoryを `inventory`、`coordinator`、`relocation`、
  `persistence` に分ける。EDIDシリアルや画面名を通常ログへ出さず、identityはprivacy指定する。

## 5. UI仕様

メイン画面は次の順に構成する。

1. 保護開始/停止、現在のDock所在、実効目標、通常/一時モード、直近エラーを表示するstatus card。
2. `ディスプレイ優先順位`。全記憶画面を順位番号、最終名称、接続/未接続、実効目標badge付きで
   表示し、drag/dropと上下ボタンで並べ替える。
3. `一時的に表示`。接続中画面を1クリックのbuttonとして表示する。一時中だけ
   `優先順位に戻す` を同じsectionへ表示する。
4. 起動、background、menu bar icon、Dock icon、theme、移動時cursor位置/offsetのsettings。

旧 `Profiles`、`Default Anchor`、永続的な単一 `Anchor Display`、`Auto Relocate` UIとモデルは削除
する。画面一覧の選択操作を永続順位変更と一時切替で兼用しない。キーボード操作、VoiceOver label、
接続状態を色だけに依存しない表示を用意する。

メニューバーは、保護状態、実効目標、開始/停止、`一時的に表示` submenu、条件付きの
`優先順位に戻す`、メイン画面を開く、update確認、終了を持つ。submenuのcheckmarkは一時目標に
だけ付け、通常目標はtitleのbadgeで示す。プロフィールsubmenuは削除する。メイン画面とmenuは
同じcoordinator instanceを購読し、別々の状態を持たない。

## 6. テスト仕様

### 6.1 自動テスト

fake inventory/locator/relocator/store/manual schedulerを使い、実時間待機なしで次を検証する。

- 空storeの初回順序、初検出画面の末尾追加、名称更新、重複正規化、EDID優先/CG UUID fallback。
- 上位接続、上位切断から次順位へのfallback、上位再接続での自動復帰、利用可能画面ゼロ。
- 一時選択が保存順を変えない、watchdogが一時目標を維持、明示returnで通常目標へ戻る。
- 接続/切断、mode/HDR相当、配置、main、sleep/wake/unlock理由が一時目標を解除する。
- 未検知KVMを模した変化なしtickでは一時目標を解除しない。
- 保護中だけ5秒schedulerが開始され、停止でstopされる。正しい所在ならrelocatorを呼ばず、
  誤り/不明なら1回呼ぶ。停止中の自動イベントは呼ばないがmanual/returnは1回呼ぶ。
- stale generationのlocator/relocator結果を破棄し、同時移動が発生しない。
- 権限、inventory、locator、relocator、storeの各失敗でcrashせず、順位/一時目標を保持し、
  適切なstatusになる。
- corrupted JSONから安全に再構築し、DockAnchor UserDefaultsを読まない。

UI testは、profile/default-anchor UIが存在しないこと、順位reorder、active-onlyの一時選択、
return buttonの表示/非表示、保護開始/停止、Accessibility案内をlaunch argumentで注入したfake状態で
検証する。実機APIへ依存するUI testを通常CIに入れない。

### 6.2 実機受入試験

署名済みDebug/Release candidateをAccessibility許可済みの2画面以上のMacで試験する。

- 優先1位/2位を設定し、1位の電源OFF/ON、ケーブル抜差し、KVMの別PC切替/復帰を行う。
- 1位で解像度、HiDPI scaling、refresh rate、HDR、回転、画面配置、main displayを変更する。
- sleep/wake、lock/unlock、clamshell（対応Macのみ）、アプリ再起動を行う。
- 各検知イベント後は一時目標が消え、保護中は5秒以内（wake安定化時間を除く）に正しい通常目標へ
  戻ることを確認する。macOSがKVM切断を報告しない場合はone-click一時切替が動作することを確認。
- 保護停止中は自動移動せず、一時選択/returnの各クリック直後だけ1回移動することを確認する。
- Accessibility拒否/取消、Dock再起動、単一画面、同型画面2台、シリアルなしadapterでもcrashしない。

## 7. 実装分担と統合順序

並列作業時は同一ファイルを複数agentへ渡さない。契約を先に確定し、以下のowner制とする。

- WP-A Foundation owner: `DisplayIdentity.swift`、`DisplayPriorityStore.swift` とstore/identity unit tests。
- WP-B System adapters owner: `SystemDisplayInventory.swift`、`DockLocator.swift`、`DockRelocator.swift`。
- WP-C Policy owner: `DockPriorityCoordinator.swift`、`WatchdogScheduler.swift` とcoordinator unit tests。
  WP-A/Bのprotocolを変更せず使用し、変更が必要なら統合ownerへ返す。
- WP-D UI owner: `ContentView.swift`、`DockPriorityApp.swift`、`AppSettings.swift`。coordinator公開APIだけを使う。
- WP-E Test owner: UI tests、integration fakes、実機checklist。production fileを編集しない。
- Integration owner: Xcode target membership、旧profile/DockMonitor/Persistenceの段階的削除、競合解消、全test。
- Independent reviewer: 統合diffと本書の各完成条件を別agentとしてreviewし、実装fileを編集しない。

統合は A/B → C → D → E の依存順に行う。並列化はAとB、Cのfake test準備、Dの静的view準備、
Eのtest matrixで行い、契約確定前に同じmodelを別々に定義しない。production behaviorを変える統合後は
独立reviewを必須とし、blocking findingを解消してからreleaseへ進む。

## 8. ビルド・配布ゲート

- Xcode project/scheme/targetは `DockPriority`、unit targetは `DockPriorityTests`、UI targetは
  `DockPriorityUITests`。deployment targetはmacOS 15.4。
- bundle IDは `io.github.cinestill800t.DockPriority`、versionは `0.1.0`、buildは `1`。
  Xcodeの `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` からInfo.plistを生成し、Swiftや別plistへ
  versionを重複定義しない。upstream signing teamを残さない。
- unit test、no-sign Debug/Release build、ad-hoc署名archive、UI test、実機matrix、独立reviewを通す。
- 0.1.0 の初回配布物は universal (`arm64` / `x86_64`) の ad-hoc署名 ZIP とする。Release archive内に
  正しいbundle/version、Accessibility説明、entitlements、署名を確認する。Developer ID署名とApple
  notarization/stapleは、このrepositoryに秘密情報やteam IDを記録せず、資格情報が明示的に利用可能に
  なった将来の配布でのみ行う。ad-hoc配布物をnotarizedと表記しない。
- 配布物は `DockPriority.app` を含む `DockPriority-0.1.0-macos.zip` とSHA-256 checksum。
  `DockPriority.app`、ZIP、DerivedData、profrawをgitへ追加しない。
- GitHub release `v0.1.0` にZIP/checksumを添付し、README、CHANGELOG、LICENSE、NOTICEをrelease前に
  最終確認する。clone直後にREADMEのbuild commandが成功することを新しい作業directoryで確認する。
