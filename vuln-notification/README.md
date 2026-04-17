# ソフトウェア脆弱性通知システム 実装ガイド

Azure Functions と Microsoft Graph を使って、脆弱性情報をグループチャット通知し、必要に応じて Planner タスクを登録するシステムです。

## 現在の実装方式

- Function 受信: HTTP Trigger (`POST /api/notify`)
- Graph 認証: 委任権限 + OBO (On-Behalf-Of)
- Teams 通知先: グループチャット (`/chats/{id}/messages`)
- Planner 連携: オプション (`planner.enabled=true` で作成)

## システム構成

```text
呼び出し元クライアント
  └─ API トークン (scope: access_as_user)
        ↓ Authorization: Bearer
Azure Functions (notify)
  ├─ OBO で Graph トークン取得
  ├─ /users で UPN 解決
  ├─ /chats でグループチャット作成 (chat_id 未指定時)
  ├─ /chats/{id}/messages で Adaptive Card 投稿
  └─ /planner/tasks でタスク作成 (オプション)

シークレット管理: Azure Key Vault
監視: Application Insights
```

## 構成イメージ

### 全体アーキテクチャ

```mermaid
flowchart TD
  A[呼び出し元クライアント] -->|POST /api/notify\nAuthorization: Bearer| B[Azure Function App\nfunc-vuln-notify-prod]

  B -->|OBO で Graph トークン取得| C[Entra ID\nvuln-notify-api-app]
  B -->|UPN 解決| D[Microsoft Graph /users]
  B -->|チャット作成| E[Microsoft Graph /chats]
  B -->|Adaptive Card 投稿| F[Microsoft Graph /chats/:chatId/messages]
  B -->|Planner タスク作成| G[Microsoft Graph /planner/tasks]

  H[Azure Key Vault\nkv-vuln-notify-prod] -->|TENANT-ID / CLIENT-ID / CLIENT-SECRET| B
  I[Application Insights] <-->|ログ・監視| B
```

### 認証フロー（OBO）

```mermaid
sequenceDiagram
  autonumber
  participant Client as 呼び出し元クライアント
  participant Func as Azure Function (notify)
  participant Entra as Entra ID
  participant Graph as Microsoft Graph

  Client->>Func: POST /api/notify\nBearer user/access_as_user token
  Func->>Entra: OBO token request\n(user assertion + CLIENT_ID/SECRET)
  Entra-->>Func: Graph delegated access token
  Func->>Graph: /users で UPN 解決
  Func->>Graph: /chats (chat_id 未指定時)
  Func->>Graph: /chats/{id}/messages
  Func->>Graph: /planner/tasks (有効時)
  Func-->>Client: 200/207 response\nchat_id / message_id / planner_task_id
```

## 主要リソース

| 種別 | 名前 |
|---|---|
| Resource Group | `vuln-notify-rg` |
| Function App | `func-vuln-notify-prod-<suffix>` |
| Key Vault | `kvvulnnotifyprod<suffix>` |

## ディレクトリ構成

```text
vuln-notification/
├── azuredeploy.bicep
├── azuredeploy.parameters.json
├── function-app/
│   ├── .funcignore
│   ├── function_app.py
│   ├── host.json
│   ├── requirements.txt
│   ├── RUNBOOK.md
│   ├── SENDER_GUIDE.md
│   ├── Test-VulnNotify.ps1       # 動作確認用 (PowerShell 版)
│   ├── test_vuln_notify.py       # 動作確認用 (Python 3.12 版)
│   └── test-vuln-notify.sh        # 動作確認用 (Bash 版)
└── README.md
```

## Entra アプリ構成（例）

### API 側アプリ

- アプリ名: `vuln-notify-api-app`
- AppId: `<API_APP_ID>`
- Expose an API:
  - Application ID URI: `api://<API_APP_ID>`
  - Scope: `access_as_user`
- Graph 委任権限:
  - `Chat.Create`
  - `ChatMessage.Send`
  - `Tasks.ReadWrite`
  - `User.ReadBasic.All`

### クライアント側アプリ

- アプリ名: `vuln-notify-client-app`
- API 側の `access_as_user` を Delegated で付与済み

## Key Vault シークレット

| シークレット名 | 用途 |
|---|---|
| `TENANT-ID` | Entra テナント ID |
| `CLIENT-ID` | API 側アプリの AppId |
| `CLIENT-SECRET` | API 側アプリのシークレット |

Function App 設定は Key Vault 参照を利用します。

## 環境構築手順（詳細）

この章は「新規環境を 0 から構築する」場合の手順です。既存環境の更新だけを行う場合は、デプロイ手順とテスト手順のみ実施してください。

### 0. GitHub から対象ファイルを取得

このガイドで利用するファイル一式は GitHub リポジトリから取得します。

#### 方法 A: `git clone`（推奨）

```powershell
git clone https://github.com/mattu0119/microsoft-security-field-notes.git
cd microsoft-security-field-notes/vuln-notification
```

#### 方法 B: ZIP ダウンロード

1. GitHub のリポジトリページで `Code` > `Download ZIP` を選択
2. ZIP を展開
3. 展開したフォルダ内の `vuln-notification` ディレクトリに移動

この後のコマンドは `vuln-notification` ディレクトリをカレントとして実行します。

### 1. 前提ツール

| ツール | 用途 | 最小バージョン |
|---|---|---|
| Azure CLI (`az`) | Azure リソース管理・デプロイ | 2.60 以上 |
| Azure Functions Core Tools (`func`) | Function App のローカル実行・デプロイ | 4.x |
| Python | Function App ランタイム / `test_vuln_notify.py` 実行 | 3.12 |
| PowerShell (Windows) / bash (macOS / Linux) | コマンド実行用シェル | PowerShell 7.0 以上 / bash 4.x 以上 |
| `curl` / `jq` (macOS / Linux) | `test-vuln-notify.sh` 実行に必要 | 任意 |
| PowerShell 7 (`pwsh`) | `Test-VulnNotify.ps1` を使う場合のみ | 7.0 以上 |

> [!NOTE]
> macOS / Linux ではテスト用に **`test_vuln_notify.py` (Python)** または **`test-vuln-notify.sh` (Bash)** を推奨します。`Test-VulnNotify.ps1` も `pwsh` をインストールすれば利用可能ですが必須ではありません。

#### インストール手順（Windows）

**Azure CLI:**

```powershell
winget install --id Microsoft.AzureCLI -e
```

> 手動インストール: <https://learn.microsoft.com/cli/azure/install-azure-cli-windows>

**Azure Functions Core Tools:**

```powershell
winget install --id Microsoft.Azure.FunctionsCoreTools -e
```

> 手動インストール: <https://learn.microsoft.com/azure/azure-functions/functions-run-local#install-the-azure-functions-core-tools>

**Python 3.12:**

```powershell
winget install --id Python.Python.3.12 -e
```

> 手動インストール: <https://www.python.org/downloads/>

**PowerShell 7:**

```powershell
winget install --id Microsoft.PowerShell -e
```

> 手動インストール: <https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows>

#### インストール手順（macOS）

Homebrew を利用する前提です。未導入の場合は <https://brew.sh> からインストールしてください。

**Azure CLI:**

```bash
brew update && brew install azure-cli
```

**Azure Functions Core Tools:**

```bash
brew tap azure/functions
brew install azure-functions-core-tools@4
```

**Python 3.12:**

```bash
brew install python@3.12
```

**PowerShell 7（`Test-VulnNotify.ps1` を使う場合のみオプション）:**

```bash
brew install --cask powershell
```

> 手動インストール: <https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-macos>

**`curl` / `jq`（`test-vuln-notify.sh` 実行に必要）:**

```bash
brew install jq
# curl は macOS に標準付属
```

#### インストール手順（Linux）

ディストリビューションにより手順が異なります。以下は Ubuntu/Debian 系の例です。RHEL/Fedora などは公式ドキュメントを参照してください。

**Azure CLI:**

```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
```

> 手動インストール: <https://learn.microsoft.com/cli/azure/install-azure-cli-linux>

**Azure Functions Core Tools:**

```bash
curl https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /etc/apt/keyrings/microsoft.gpg > /dev/null
sudo sh -c 'echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/microsoft-$(lsb_release -cs)-prod $(lsb_release -cs) main" > /etc/apt/sources.list.d/microsoft-prod.list'
sudo apt-get update
sudo apt-get install -y azure-functions-core-tools-4
```

> 手動インストール: <https://learn.microsoft.com/azure/azure-functions/functions-run-local#install-the-azure-functions-core-tools>

**Python 3.12:**

```bash
sudo apt-get install -y python3.12 python3.12-venv python3-pip
```

> [!NOTE]
> Ubuntu 22.04 など python3.12 パッケージが既定リポジトリに存在しないディストリビューションでは、事前に `deadsnakes` PPA を追加してください。
>
> ```bash
> sudo add-apt-repository -y ppa:deadsnakes/ppa
> sudo apt-get update
> ```

> 手動インストール: <https://www.python.org/downloads/>

**PowerShell 7（`Test-VulnNotify.ps1` を使う場合のみオプション）:**

```bash
sudo apt-get install -y wget apt-transport-https software-properties-common
source /etc/os-release
wget -q "https://packages.microsoft.com/config/ubuntu/$VERSION_ID/packages-microsoft-prod.deb"
sudo dpkg -i packages-microsoft-prod.deb
rm packages-microsoft-prod.deb
sudo apt-get update
sudo apt-get install -y powershell
```

> 手動インストール: <https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux>

**`zip` コマンド（デプロイパッケージ作成用） / `curl` / `jq`（`test-vuln-notify.sh` 実行用）:**

```bash
sudo apt-get install -y zip curl jq
```

> [!NOTE]
> macOS / Linux ではテストスクリプトとして `test_vuln_notify.py` （Python 3.12）または `test-vuln-notify.sh` （Bash）を使用できます。`Test-VulnNotify.ps1` を使う場合のみ `pwsh` をインストールしてください。

#### バージョン確認

**Windows (PowerShell):**

```powershell
az version
func --version
python --version
$PSVersionTable.PSVersion
```

**macOS / Linux (bash):**

```bash
az version
func --version
python3 --version
curl --version | head -n1   # test-vuln-notify.sh 実行用
jq --version                # test-vuln-notify.sh 実行用
pwsh -Version               # Test-VulnNotify.ps1 を使う場合のみ
```

すべてのコマンドが正常に実行でき、バージョンが要件を満たしていることを確認してから次に進んでください。

### 1-1. リソース展開に必要な Azure ロール

このテンプレートではリソース作成に加えて、Key Vault スコープのロール割り当て (`Microsoft.Authorization/roleAssignments`) も実行します。

最小構成の目安:

| スコープ | 必要ロール | 用途 |
|---|---|---|
| サブスクリプション（または対象 RG） | `Contributor` | Resource Group / Function App / Key Vault などのリソース作成 |
| 対象 Resource Group（または Key Vault） | `User Access Administrator` | Function の Managed Identity に Key Vault Secrets User ロールを付与 |

簡易運用では `Owner` を付与しても実行できますが、公開環境では上記 2 ロール分離を推奨します。

### 1-2. Entra ID の管理者同意に必要なロール

Step 4 の Entra アプリ構成で `管理者の同意を与えます（Grant admin consent）` を実行するには、以下のいずれかの Entra ID ロールが必要です。

| Entra ID ロール | 備考 |
|---|---|
| `Cloud Application Administrator` | 推奨（最小権限） |
| `Application Administrator` | |
| `Privileged Role Administrator` | |
| `Global Administrator` | 最も広い権限。必要な場合のみ |

> [!NOTE]
> ロールが不足している場合、Azure portal の `管理者の同意を与えます` ボタンがグレーアウトされます。テナント管理者に依頼して、上記いずれかのロールを付与してもらってください。

### 2. Azure サインインとサブスクリプション選択

**Windows (PowerShell) / macOS / Linux (bash) 共通:**

```bash
az login
az account list --output table
az account set --subscription "<SUBSCRIPTION_ID_OR_NAME>"
az account show --output table
```

### 3. インフラを Bicep で展開

リソース グループを作成後、Bicep を実行します。

**Windows (PowerShell):**

```powershell
$resourceGroupName = "vuln-notify-rg"
$location = "japaneast"
$deploymentName = "vuln-notify-infra"

az group create --name $resourceGroupName --location $location

az deployment group create \
  --name $deploymentName \
  --resource-group $resourceGroupName \
  --template-file azuredeploy.bicep \
  --parameters @azuredeploy.parameters.json
```

**macOS / Linux (bash):**

```bash
resourceGroupName="vuln-notify-rg"
location="japaneast"
deploymentName="vuln-notify-infra"

az group create --name $resourceGroupName --location $location

az deployment group create \
  --name "$deploymentName" \
  --resource-group $resourceGroupName \
  --template-file azuredeploy.bicep \
  --parameters @azuredeploy.parameters.json
```

1行版:

```powershell
az deployment group create --name $deploymentName --resource-group $resourceGroupName --template-file azuredeploy.bicep --parameters "@azuredeploy.parameters.json"
```

必要に応じてサフィックスを明示指定できます。

```powershell
az deployment group create \
  --name $deploymentName \
  --resource-group $resourceGroupName \
  --template-file azuredeploy.bicep \
  --parameters @azuredeploy.parameters.json \
  --parameters nameSuffix=dev01
```

1行版:

```powershell
az deployment group create --name $deploymentName --resource-group $resourceGroupName --template-file azuredeploy.bicep --parameters "@azuredeploy.parameters.json" --parameters nameSuffix=dev01
```

展開後に以下が作成されていることを確認します。

**Windows (PowerShell):**

```powershell
$funcApp = az deployment group show -g $resourceGroupName -n $deploymentName --query "properties.outputs.functionAppName.value" -o tsv
$kvName = az deployment group show -g $resourceGroupName -n $deploymentName --query "properties.outputs.keyVaultName.value" -o tsv

"Function App: $funcApp"
"Key Vault: $kvName"
```

**macOS / Linux (bash):**

```bash
funcApp=$(az deployment group show -g $resourceGroupName -n "$deploymentName" --query "properties.outputs.functionAppName.value" -o tsv)
kvName=$(az deployment group show -g $resourceGroupName -n "$deploymentName" --query "properties.outputs.keyVaultName.value" -o tsv)

echo "Function App: $funcApp"
echo "Key Vault: $kvName"
```

### 4. Entra アプリを準備（OBO 用）

この手順は Azure portal で実施します。

#### Step 1. API 側アプリを作成

1. Entra ID > アプリの登録 > 新規登録 を開く
2. 名前を `vuln-notify-api-app` にして作成
3. 作成後、`アプリケーション (クライアント) ID` を控える（後で `<API_APP_ID>` として使用）

<p align="center">
  <img src="images/image-3.png" alt="Entra ID アプリの登録画面で vuln-notify-api-app を新規登録する画面" width="900" />
</p>
<p align="center"><em>Step 1: Entra ID でアプリを新規登録</em></p>

#### Step 2. API 側で Expose an API を設定

1. `vuln-notify-api-app` の Expose an API を開く
2. Application ID URI を `api://<API_APP_ID>` で設定

<p align="center">
  <img src="images/image.png" alt="Expose an API で access_as_user スコープを設定する画面" width="900" />
</p>
<p align="center"><em>Step 2: Expose an API で access_as_user スコープを追加</em></p>

3. Scope を追加:
   - Scope 名: `access_as_user`
   - 管理者の同意の表示名: `Access vuln-notify API as user`（管理者が同意画面で確認する名称）
   - 管理者の同意の説明: 例 `この API が Teams 通知と Planner タスク作成に必要なアクセスを行うことを許可します。`（必須）
   - 状態: Enabled

<p align="center">
  <img src="images/image-4.png" alt="Scope 追加時に管理者同意の表示名を設定する画面" width="900" />
</p>
<p align="center"><em>Step 2: Scope 追加時に管理者同意の表示名を入力</em></p>

> [!NOTE]
> 管理者の同意は、テナント管理者がアプリ権限を組織に対して承認する操作です。未実施の場合、ユーザーがトークン取得に失敗し、OBO フローが成立しません。


#### Step 3. API 側に Graph Delegated Permissions を追加

1. `vuln-notify-api-app` > API のアクセス許可 を開く

<p align="center">
  <img src="images/image-5.png" alt="API のアクセス許可画面で Add a permission をクリックする画面" width="900" />
</p>
<p align="center"><em>Step 3: API のアクセス許可から権限を追加</em></p>

2. Microsoft Graph の Delegated permissions を追加:
   - `Chat.Create`
   - `ChatMessage.Send`
   - `Tasks.ReadWrite`（Planner タスクの作成・更新に必要）
   - `User.ReadBasic.All`（UPN からユーザー情報を解決するために必要）
3. `管理者の同意を与えます` を実行して Granted 状態を確認

<p align="center">
  <img src="images/image-6.png" alt="Microsoft Graph を選択し Delegated permissions で権限を検索・追加する手順画面" width="900" />
</p>
<p align="center"><em>Step 3: Microsoft Graph > Delegated permissions から必要な権限を追加</em></p>

#### Step 4. API 側アプリの Client secret を作成

1. `vuln-notify-api-app` > 証明書とシークレット を開く
2. 新しいクライアント シークレットを作成
3. シークレット値を控える（この画面を閉じると再表示不可）
4. この値を `<API_APP_CLIENT_SECRET>` として Key Vault シークレット投入時に使用

<p align="center">
  <img src="images/image-7.png" alt="Certificates & secrets 画面で New client secret を作成する手順" width="900" />
</p>
<p align="center"><em>Step 4: 証明書とシークレットからクライアントシークレットを作成</em></p>

> [!TIP]
> 本番運用では有効期限の 30 日以上前にシークレットを再発行し、Key Vault の `CLIENT-SECRET` を更新してください。更新後は Function App を再起動して新シークレット参照を反映します。

#### Step 5. クライアント側アプリを作成

1. Entra ID > アプリの登録 > 新規登録 を開く
2. 名前を `vuln-notify-client-app` にして作成
3. 作成後、クライアント側 AppId を控える（必要に応じて）

#### Step 6. クライアント側に API スコープを付与

1. `vuln-notify-client-app` > API のアクセス許可 を開く
2. `アクセス許可の追加` をクリック
3. `所属する組織で使用している API` を選択し、`vuln-notify-api-app` を検索して選択
4. `委任されたアクセス許可` を選択し、`access_as_user` をチェックして `アクセス許可の追加` を実行

<p align="center">
  <img src="images/image-8.png" alt="クライアント側アプリで vuln-notify-api-app の access_as_user を Delegated permissions として追加する画面" width="900" />
</p>
<p align="center"><em>Step 6: クライアント側アプリに access_as_user の委任権限を付与</em></p>

5. 必要に応じて `管理者の同意を与えます` を実行し、`Granted` 状態を確認

<p align="center">
  <img src="images/image-9.png" alt="クライアント側アプリの API permissions 画面で Grant admin consent を実行する画面" width="900" />
</p>
<p align="center"><em>Step 6: Grant admin consent をクリックして管理者同意を付与</em></p>

> [!WARNING]
> クライアント側で `access_as_user` が付与されていない場合、`api://<API_APP_ID>/access_as_user` のトークン取得に失敗します。

#### Step 7. 最終確認（OBO 前提）

以下が揃っていれば OBO 前提の Entra 構成は完了です。

- API 側 AppId が取得できている
- API 側で `access_as_user` が公開済み
- クライアント側で `access_as_user` が付与済み
- Graph Delegated permissions が Granted 済み
- API 側 Client secret が払い出し済み

### 5. Key Vault シークレットを投入

この手順は Azure CLI で実施します。まず対象 Key Vault 名を取得してから、必要シークレットを登録します。

#### Step 1. 対象 Key Vault 名を取得

**Windows (PowerShell):**

```powershell
$kvName = az deployment group show -g $resourceGroupName -n $deploymentName --query "properties.outputs.keyVaultName.value" -o tsv
"Key Vault: $kvName"
```

**macOS / Linux (bash):**

```bash
kvName=$(az deployment group show -g $resourceGroupName -n "$deploymentName" --query "properties.outputs.keyVaultName.value" -o tsv)
echo "Key Vault: $kvName"
```

#### Step 2. 自分自身に Key Vault Secrets Officer ロールを付与

この Key Vault は RBAC 認可モードで構成されているため、シークレットの読み書きには Azure RBAC ロールが必要です。

**Windows (PowerShell):**

```powershell
$currentUser = az ad signed-in-user show --query id -o tsv
$kvId = az keyvault show --name $kvName --query id -o tsv

az role assignment create `
  --role "Key Vault Secrets Officer" `
  --assignee-object-id $currentUser `
  --assignee-principal-type User `
  --scope $kvId
```

**macOS / Linux (bash):**

```bash
currentUser=$(az ad signed-in-user show --query id -o tsv)
kvId=$(az keyvault show --name "$kvName" --query id -o tsv)

az role assignment create \
  --role "Key Vault Secrets Officer" \
  --assignee-object-id $currentUser \
  --assignee-principal-type User \
  --scope $kvId
```

1行版:

```powershell
az role assignment create --role "Key Vault Secrets Officer" --assignee-object-id $currentUser --assignee-principal-type User --scope $kvId
```

> [!NOTE]
> ロール割り当て後、反映まで数分かかる場合があります。`Forbidden` エラーが出る場合は少し待ってから再実行してください。

付与を確認:

```bash
az role assignment list --scope $kvId --assignee $currentUser --output table
```

#### Step 3. 必須シークレットを登録

**Windows (PowerShell) / macOS / Linux (bash) 共通:**

```bash
az keyvault secret set --vault-name $kvName --name TENANT-ID --value "<TENANT_ID>"
az keyvault secret set --vault-name $kvName --name CLIENT-ID --value "<API_APP_ID>"
az keyvault secret set --vault-name $kvName --name CLIENT-SECRET --value "<API_APP_CLIENT_SECRET>"
```

> [!NOTE]
> PowerShell では `$kvName` をダブルクオートにしなくても展開されます。bash では `"$kvName"` のようにダブルクオートで囲んでください。

#### Step 4. 登録結果を確認

```bash
az keyvault secret show --vault-name "$kvName" --name TENANT-ID --query id -o tsv
az keyvault secret show --vault-name "$kvName" --name CLIENT-ID --query id -o tsv
az keyvault secret show --vault-name "$kvName" --name CLIENT-SECRET --query id -o tsv
```

#### Step 5. 値の整合性チェック（推奨）

```bash
az keyvault secret show --vault-name "$kvName" --name CLIENT-ID --query value -o tsv
```

- 出力された `CLIENT-ID` が `vuln-notify-api-app` の AppId と一致していることを確認
- `CLIENT-SECRET` は平文確認を最小限にし、ログや履歴に残さない運用を推奨

### 6. Function App 設定の反映確認

Function App のアプリ設定で Key Vault 参照が正しく構成されていることを確認し、必要に応じて再起動します。

#### Step 1. Function App 名を取得

**Windows (PowerShell):**

```powershell
$funcApp = az deployment group show -g $resourceGroupName -n "$deploymentName" --query "properties.outputs.functionAppName.value" -o tsv
"Function App: $funcApp"
```

**macOS / Linux (bash):**

```bash
funcApp=$(az deployment group show -g $resourceGroupName -n $deploymentName --query "properties.outputs.functionAppName.value" -o tsv)
echo "Function App: $funcApp"
```

> [!WARNING]
> 出力が空の場合、`$deploymentName` / `deploymentName` 変数が未定義の可能性があります。新しいターミナルを開いた場合は変数が失われるため、以下を再実行してください。
>
> ```powershell
> # Windows (PowerShell)
> $deploymentName = "vuln-notify-infra"
> ```
>
> ```bash
> # macOS / Linux (bash)
> deploymentName="vuln-notify-infra"
> ```

#### Step 2. アプリ設定を確認

**Windows (PowerShell) / macOS / Linux (bash) 共通:**

```bash
az functionapp config appsettings list \
  --name $funcApp \
  --resource-group $resourceGroupName \
  --output table
```

1行版:

```powershell
az functionapp config appsettings list --name $funcApp --resource-group $resourceGroupName --output table
```

確認ポイント:

- `TENANT_ID`
- `CLIENT_ID`
- `CLIENT_SECRET`

上記 3 つが存在し、値が `@Microsoft.KeyVault(...)` 形式で設定されていることを確認します。

#### Step 3. Function App を再起動して参照を再読込

```bash
az functionapp restart \
  --name $funcApp \
  --resource-group $resourceGroupName
```

#### Step 4. 反映後の動作確認（最小）

```bash
az functionapp show --name $funcApp --resource-group $resourceGroupName --query "properties.state" -o tsv
```

- `Running` を確認
- その後、本 README の「テスト手順」を実行して `status: sent` を確認

### 7. Function App のコードデプロイ

Function App のコード（`function_app.py` 等）を Azure にデプロイします。本テンプレートは **Flex Consumption プラン** を使用しており、デプロイ用パッケージの格納先は Bicep で構成済みの専用 Blob コンテナー（`deploymentpackage`）です。このコンテナーへの書き込みは Function App の **システム割り当て Managed Identity** によって Azure プラットフォーム側が自動的に実行するため、利用者は `func` / `az` CLI で zip を送るだけで済みます。

> [!NOTE]
> Flex Consumption では `WEBSITE_RUN_FROM_PACKAGE` は **サポート外**です。代わりに `functionAppConfig.deployment.storage`（本テンプレートでは `deploymentpackage` コンテナー + SystemAssignedIdentity）に基づくデプロイ モデルを使用します。
> 根拠: [Flex Consumption plan - Considerations](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan#considerations) / [Deployment sources on Flex Consumption](https://learn.microsoft.com/azure/azure-functions/flex-consumption-how-to#deploy-project-files)

#### 前提

- Azure Functions Core Tools **v4.0.6280 以上**（Flex Consumption サポートが含まれるバージョン）
- Function App に対する `Contributor` 相当のロール（Kudu publish エンドポイント呼び出しに必要）
- デプロイ ストレージへの書き込み権限は Function App の Managed Identity 側で構成済み（Bicep で `Storage Blob Data Owner` を自動付与）。**利用者に `Storage Blob Data Contributor` 等の追加付与は不要**

#### Step 1. Function App 名を取得

**Windows (PowerShell):**

```powershell
$deploymentName = "vuln-notify-infra"
$funcApp = az deployment group show -g $resourceGroupName -n $deploymentName --query "properties.outputs.functionAppName.value" -o tsv
"Function App: $funcApp"
```

**macOS / Linux (bash):**

```bash
deploymentName="vuln-notify-infra"
funcApp=$(az deployment group show -g $resourceGroupName -n $deploymentName --query "properties.outputs.functionAppName.value" -o tsv)
echo "Function App: $funcApp"
```

#### Step 2. `func azure functionapp publish` でデプロイ（推奨）

`function-app` ディレクトリから Core Tools の標準コマンドを実行します。Core Tools が zip を作成し Kudu の publish エンドポイントへ送信、プラットフォームが MI で `deploymentpackage` コンテナーへ格納します。

**Windows (PowerShell):**

```powershell
Push-Location function-app
func azure functionapp publish $funcApp --python
Pop-Location
```

**macOS / Linux (bash):**

```bash
pushd function-app
func azure functionapp publish $funcApp --python
popd
```

> [!TIP]
> 依存関係はプラットフォーム側で `requirements.txt` に基づきリモート ビルドされます（Flex Consumption の既定動作）。ローカルで `.python_packages/` を事前作成する必要はありません。
> 根拠: [Deploy project files (Flex Consumption)](https://learn.microsoft.com/azure/azure-functions/flex-consumption-how-to#deploy-project-files)

デプロイ完了後、動作確認:

```bash
az functionapp show --name $funcApp --resource-group $resourceGroupName --query "properties.state" -o tsv
```

`Running` が返れば OK です。

#### Step 3（代替）: `az functionapp deploy` で zip を送る

CI/CD など Core Tools を導入できない環境向けに、Azure CLI の OneDeploy コマンドで zip を直接送信することもできます。Flex Consumption でも正式にサポートされています。

**macOS / Linux (bash):**

```bash
pushd function-app
zip -r ../deploy.zip . -x "*.pyc" "__pycache__/*" ".venv/*"
popd

az functionapp deploy \
  --resource-group $resourceGroupName \
  --name $funcApp \
  --src-path ./deploy.zip \
  --type zip

rm deploy.zip
```

**Windows (PowerShell):**

```powershell
Push-Location function-app
Compress-Archive -Path * -DestinationPath ..\deploy.zip -Force
Pop-Location

az functionapp deploy `
  --resource-group $resourceGroupName `
  --name $funcApp `
  --src-path .\deploy.zip `
  --type zip

Remove-Item deploy.zip
```

> [!NOTE]
> `az functionapp deployment source config-zip` は Flex Consumption では**非推奨**です。Flex Consumption では上記 `az functionapp deploy --type zip`（OneDeploy）を使用してください。
> 根拠: [Deployment technologies in Azure Functions](https://learn.microsoft.com/azure/azure-functions/functions-deployment-technologies) / [az functionapp deploy](https://learn.microsoft.com/cli/azure/functionapp#az-functionapp-deploy)

> [!TIP]
> `pip` コマンドが「Access is denied」で失敗する場合は `python -m pip` を使用してください。Python の Scripts フォルダに実行権限がない環境でも `python -m pip` は動作します。

### 8. Planner ID / Bucket ID を取得

Planner タスク連携を使う場合は `plan_id` と `bucket_id` が必要です。

#### 前提条件

- Planner プランが作成済みであること
- 自分がそのプランの所属する **Microsoft 365 グループのメンバー**であること

プランが未作成の場合は、以下のいずれかの方法で事前に作成してください。

| 方法 | 手順 |
|---|---|
| Teams から作成 | 対象チャネルで `+` タブ追加 > `Tasks by Planner` を選択 > 新しいプランを作成 |
| Web から作成 | [tasks.office.com](https://tasks.office.com) にアクセスし、`新しいプラン` を作成 |

プラン作成者は自動的に所有者兼メンバーになるため、作成後すぐに Plan ID を取得できます。

#### Step 1. Graph トークンを取得

**Windows (PowerShell):**

```powershell
$graphToken = az account get-access-token --resource-type ms-graph --query accessToken -o tsv
$graphHeaders = @{ Authorization = "Bearer $graphToken" }
```

**macOS / Linux (bash):**

```bash
graphToken=$(az account get-access-token --resource-type ms-graph --query accessToken -o tsv)
```

#### Step 2. 利用可能な Planner Plan を確認

**Windows (PowerShell) / macOS / Linux (bash) 共通:**

```bash
az rest \
  --method GET \
  --url "https://graph.microsoft.com/v1.0/me/planner/plans" \
  --headers "Authorization=Bearer $graphToken" \
  --output json
```

1行版:

```powershell
az rest --method GET --url "https://graph.microsoft.com/v1.0/me/planner/plans" --headers "Authorization=Bearer $graphToken" --output json
```

出力の `value[].id` が Planner Plan ID (`plan_id`) です。

> [!NOTE]
> `/me/planner/plans` は自分がメンバーになっている Planner プランのみ返します。`"value": []` で空の場合は、対象プランが所属する Microsoft 365 グループのメンバーになっているか確認してください。プランが未作成の場合は、Teams チャネルで `Tasks by Planner` タブを追加するか [tasks.office.com](https://tasks.office.com) で新規作成します。

<p align="center">
  <img src="images/image-10.png" alt="Graph API /me/planner/plans の実行結果で Plan ID を確認する画面" width="900" />
</p>
<p align="center"><em>Step 2: /me/planner/plans の出力から id（Plan ID）を取得</em></p>

#### Step 3. Plan に属する Bucket を確認

**Windows (PowerShell):**

```powershell
$planId = "<PLAN_ID>"

az rest \
  --method GET \
  --url "https://graph.microsoft.com/v1.0/planner/plans/$planId/buckets" \
  --headers "Authorization=Bearer $graphToken" \
  --output json
```

**macOS / Linux (bash):**

```bash
planId="<PLAN_ID>"

az rest \
  --method GET \
  --url "https://graph.microsoft.com/v1.0/planner/plans/$planId/buckets" \
  --headers "Authorization=Bearer $graphToken" \
  --output json
```

1行版:

```powershell
az rest --method GET --url "https://graph.microsoft.com/v1.0/planner/plans/$planId/buckets" --headers "Authorization=Bearer $graphToken" --output json
```

出力の `value[].id` が Bucket ID (`bucket_id`) です。

#### Step 4. PowerShell で見やすく一覧表示（任意）

```powershell
$plans = Invoke-RestMethod -Method GET -Uri "https://graph.microsoft.com/v1.0/me/planner/plans" -Headers $graphHeaders
$plans.value | Select-Object id,title,owner | Format-Table -AutoSize

$planId = "<PLAN_ID>"
$buckets = Invoke-RestMethod -Method GET -Uri "https://graph.microsoft.com/v1.0/planner/plans/$planId/buckets" -Headers $graphHeaders
$buckets.value | Select-Object id,name,orderHint | Format-Table -AutoSize
```

#### Step 5. 取得した ID をテスト手順へ反映

- `-PlannerPlanId` に `plan_id` を指定
- `-PlannerBucketId` に `bucket_id` を指定
- JSON で送る場合は `planner.plan_id` と `planner.bucket_id` に指定

## API 仕様（現在）

### エンドポイント

```http
POST https://<FUNCTION_APP_NAME>.azurewebsites.net/api/notify
Headers:
  Authorization: Bearer <user token or access_as_user token>
Content-Type: application/json
```

### 最小リクエスト例

```json
{
  "upns": [
    "analyst01@contoso.com",
    "owner01@contoso.com"
  ],
  "title": "脆弱性通知: CVE-2026-12345",
  "message": "OpenSSL の重大脆弱性を検知しました。"
}
```

### Planner 連携を有効化する例

```json
{
  "upns": [
    "analyst01@contoso.com",
    "owner01@contoso.com",
    "manager01@contoso.com"
  ],
  "planner": {
    "enabled": true,
    "plan_id": "<PLANNER_PLAN_ID>",
    "bucket_id": "<PLANNER_BUCKET_ID>"
  },
  "facts": {
    "cve_id": "CVE-2026-12345",
    "severity": "High",
    "cvss": "9.1",
    "component": "OpenSSL",
    "due_date": "2026-04-13"
  }
}
```

### Planner 担当者の仕様

- 既定: `upns` の全員を担当者として割り当て
- `planner.assignee_upn` を指定した場合: その 1 名のみ割り当て
- `planner.assignee_upns` を指定した場合: 指定した複数 UPN を割り当て

### 9. テスト手順

#### 前提: Azure CLI 用の管理者同意を構成

Azure CLI（`az login --scope`）でテスト用トークンを取得するには、Azure CLI アプリ（AppId: `04b07795-8ddb-461a-bbee-02f9e1bf7b46`）に対して API スコープへの管理者同意が必要です。

##### 方法 A: knownClientApplications に Azure CLI を追加（推奨）

1. Azure portal で [Entra ID](https://entra.microsoft.com) > **アプリの登録** を開く
2. `vuln-notify-api-app` を選択
3. 左メニューの **マニフェスト** をクリック
4. JSON エディタで `knownClientApplications` を検索し、以下のように変更:
   ```json
   "knownClientApplications": ["04b07795-8ddb-461a-bbee-02f9e1bf7b46"]
   ```
   > `04b07795-...` は Azure CLI の固定 AppId です。これを追加することで、Azure CLI がこの API のスコープを利用する際に同意が自動適用されます。

<p align="center">
  <img src="images/image-manifest-known-client.png" alt="vuln-notify-api-app のマニフェスト画面で knownClientApplications に Azure CLI の AppId を設定した画面" width="900" />
</p>
<p align="center"><em>方法 A: マニフェストで knownClientApplications に Azure CLI AppId を追加</em></p>

5. 画面上部の **保存** をクリック
6. 左メニューの **API のアクセス許可** に移動
7. **\<テナント名\> に管理者の同意を与えます** をクリックし、確認ダイアログで **はい** を選択
8. すべての権限が **✅ Granted（付与済み）** になっていることを確認

これにより Azure CLI 経由でのトークン取得時に、API 側の同意が自動的に適用されます。

##### 方法 B: 管理者同意 URL を使う

管理者に以下の URL をブラウザで開いてもらい、同意を付与してもらいます。

```text
https://login.microsoftonline.com/<TENANT_ID>/adminconsent?client_id=04b07795-8ddb-461a-bbee-02f9e1bf7b46&scope=api://<API_APP_ID>/access_as_user
```

> [!NOTE]
> 管理者同意の付与には以下のいずれかの Entra ID ロールが必要です。
>
> | ロール | 備考 |
> |---|---|
> | `Cloud Application Administrator` | 推奨（最小権限）|
> | `Application Administrator` | |
> | `Global Administrator` | 最も広い権限 |
>
> 同意が未付与の場合、`az login --scope` 実行時に「管理者の承認が必要」画面が表示されます。

#### トークン取得

初回のみ、Azure CLI でカスタム API スコープへの対話的ログインが必要です。

```bash
az logout
az login --scope "api://<API_APP_ID>/access_as_user"
```

同意済みであれば、トークン取得とテスト実行を行います。

**Windows (PowerShell) — `Test-VulnNotify.ps1`:**

```powershell
$token = az account get-access-token --scope "api://<API_APP_ID>/access_as_user" --query accessToken -o tsv

.\function-app\Test-VulnNotify.ps1 `
  -UserAccessToken $token `
  -FunctionAppName $funcApp `
  -Upns '<YOUR_UPN>','analyst01@contoso.com','owner01@contoso.com' `
  -CreatePlannerTask `
  -PlannerPlanId '<PLANNER_PLAN_ID>' `
  -PlannerBucketId '<PLANNER_BUCKET_ID>'
```

**macOS / Linux (bash) — `test_vuln_notify.py` (Python 3.12, 推奨):**

> 標準ライブラリのみで動作します。`pip install` 不要。

```bash
token=$(az account get-access-token --scope "api://<API_APP_ID>/access_as_user" --query accessToken -o tsv)

python3 ./function-app/test_vuln_notify.py \
  --user-access-token "$token" \
  --function-app-name "$funcApp" \
  --upns '<YOUR_UPN>' analyst01@contoso.com owner01@contoso.com \
  --create-planner-task \
  --planner-plan-id '<PLANNER_PLAN_ID>' \
  --planner-bucket-id '<PLANNER_BUCKET_ID>'
```

**macOS / Linux (bash) — `test-vuln-notify.sh` (Bash):**

> `curl` / `jq` がインストール済みであること。`--upns` はカンマ区切りで指定します。

```bash
token=$(az account get-access-token --scope "api://<API_APP_ID>/access_as_user" --query accessToken -o tsv)

./function-app/test-vuln-notify.sh \
  --user-access-token "$token" \
  --function-app-name "$funcApp" \
  --upns '<YOUR_UPN>,analyst01@contoso.com,owner01@contoso.com' \
  --create-planner-task \
  --planner-plan-id '<PLANNER_PLAN_ID>' \
  --planner-bucket-id '<PLANNER_BUCKET_ID>'
```

**macOS / Linux (bash + pwsh) — `Test-VulnNotify.ps1` (オプション):**

> PowerShell スクリプトをそのまま使いたい場合だけ `pwsh` 経由で実行します。

```bash
token=$(az account get-access-token --scope "api://<API_APP_ID>/access_as_user" --query accessToken -o tsv)

pwsh -File ./function-app/Test-VulnNotify.ps1 \
  -UserAccessToken "$token" \
  -FunctionAppName "$funcApp" \
  -Upns '<YOUR_UPN>','analyst01@contoso.com','owner01@contoso.com' \
  -CreatePlannerTask \
  -PlannerPlanId '<PLANNER_PLAN_ID>' \
  -PlannerBucketId '<PLANNER_BUCKET_ID>'
```

#### 主なオプション対応表

3 つのスクリプトは同一のペイロードを送信します。主なオプション名の対応は以下のとおりです。

| 用途 | `Test-VulnNotify.ps1` | `test_vuln_notify.py` | `test-vuln-notify.sh` |
|---|---|---|---|
| Function App 名 | `-FunctionAppName` | `--function-app-name` | `--function-app-name` |
| ユーザートークン | `-UserAccessToken` | `--user-access-token` | `--user-access-token` |
| Graph トークン (az CLI) | `-UseAzGraphToken` | `--use-az-graph-token` | `--use-az-graph-token` |
| UPN 一覧 | `-Upns 'a','b'` | `--upns a b` (スペース区切り) | `--upns 'a,b'` (カンマ区切り) |
| Planner 作成 | `-CreatePlannerTask` | `--create-planner-task` | `--create-planner-task` |
| Plan ID | `-PlannerPlanId` | `--planner-plan-id` | `--planner-plan-id` |
| Bucket ID | `-PlannerBucketId` | `--planner-bucket-id` | `--planner-bucket-id` |
| 担当者 UPN (単一) | `-PlannerAssigneeUpn` | `--planner-assignee-upn` | `--planner-assignee-upn` |

環境変数フォールバック (`VULN_NOTIFY_USER_TOKEN` / `VULN_NOTIFY_UPNS` / `VULN_NOTIFY_PLANNER_PLAN_ID` / `VULN_NOTIFY_PLANNER_BUCKET_ID` / `VULN_NOTIFY_PLANNER_ASSIGNEE_UPN`) は 3 つとも共通でサポートしています。

> [!WARNING]
> 以下のような `consent_required` / `AADSTS65001` エラーが表示された場合は、Azure CLI 用の管理者同意が未構成です。上記「前提: Azure CLI 用の管理者同意を構成」の手順を実施してください。
>
> <p align="center">
>   <img src="images/image-consent-required-error.png" alt="az account get-access-token 実行時に consent_required エラーが発生した画面" width="900" />
> </p>
> <p align="center"><em>consent_required エラーの例: 管理者同意が未付与の場合に発生</em></p>

> [!IMPORTANT]
> `-Upns` / `--upns` には **自分自身の UPN を必ず含めてください**。グループチャット作成 API (`POST /chats`) は、呼び出し元ユーザーがメンバーに含まれていることを要求します。自分の UPN が含まれていない場合、`The caller must be one of the members specified in request body` エラーが発生します。

#### 最近の検証結果

- グループチャット投稿: 成功
- Planner タスク作成: 成功
- Planner 担当者 3 名割り当て: 成功

## 補足ドキュメント

詳細手順は `function-app/RUNBOOK.md` を参照してください。

送信側実装は `function-app/SENDER_GUIDE.md` を参照してください。
