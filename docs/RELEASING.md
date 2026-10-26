# 发布与验证

Tidest 的正式安装包由 GitHub Actions 从版本标签对应的公开源码构建。流程依次完成通用版本编译、Developer ID 签名、Apple 公证、附上公证票据、生成构建来源证明、上传草稿、下载复核和发布。

一个版本对应一个源码提交和一个固定的 DMG。所有检查通过后，流程会自动发布；发布标签之前应确认源码和版本号已经准备好。

## 首次配置 GitHub

### 1. 开启不可变发布

打开 [仓库 Settings](https://github.com/mixBayes/Tidest/settings)，在 General 页面的 Releases 区域勾选 **Enable release immutability**。

它只影响未来发布。发布后不能追加、替换或删除单个附件，也不能移动对应标签；修复安装包需要使用新版本号。标题和发布说明仍可编辑。整个 Release 仍可被删除，但相同标签名不能再次使用，因此不可变发布不是永久文件存储承诺。

### 2. 创建发布环境

打开 **Settings → Environments → New environment**，创建名为 **release** 的环境。

在此环境的 **Deployment branches and tags** 中选择 **Selected branches and tags**，添加一个类型为 **Tag**、名称为 `v*` 的规则。签名和公证凭据只在发布版本标签时使用。

流程使用的 Actions 均来自 GitHub 官方，并固定到完整提交 SHA。如果仓库限制了可使用的 Actions，需要允许 `actions/checkout`、`actions/attest` 和 `actions/upload-artifact`。

### 3. 添加一个环境变量

在 release 环境的 **Environment variables** 中添加：

| Name | Value |
| --- | --- |
| `APPLE_TEAM_ID` | Apple Developer 的 10 位 Team ID，可在开发者账户的 Membership details 中查看 |

Team ID 不是密码，会写入公开构建信息，供用户核对签名身份。

### 4. 添加四个环境 Secret

在同一个 release 环境的 **Environment secrets** 中添加：

| Name | Secret |
| --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | 包含 Developer ID Application 证书及其私钥的 p12 文件，转换为 Base64 后的内容 |
| `APPLE_CERTIFICATE_PASSWORD` | 导出该 p12 文件时设置的密码 |
| `APPLE_ID` | 有权为此 Team 公证软件的 Apple 账户邮箱 |
| `APPLE_APP_SPECIFIC_PASSWORD` | 为该 Apple 账户生成的 App 专用密码，不是账户登录密码 |

获取 p12：

1. 在 Mac 打开“钥匙串访问”，进入“我的证书”。
2. 找到 **Developer ID Application: … (TEAMID)**，确认展开后包含对应私钥。
3. 选择此证书并导出为 p12，设置一个非空密码。不要选择 Apple Development 或 Developer ID Installer。
4. 将文件保存在仓库外，例如下载文件夹。在终端执行下面的命令，修改为实际路径，结果会直接进入剪贴板：

~~~sh
base64 -i "$HOME/Downloads/Tidest-DeveloperID.p12" | pbcopy
~~~

5. 将剪贴板粘贴到 `APPLE_CERTIFICATE_P12_BASE64`，将导出密码单独填入 `APPLE_CERTIFICATE_PASSWORD`。

在 [Apple 账户](https://account.apple.com/) 的“登录和安全性 → App 专用密码”中生成一个专用密码，填入 `APPLE_APP_SPECIFIC_PASSWORD`。

不要将证书、私钥或密码发到 Issue、聊天、构建参数或代码仓库。流程临时导入证书，结束时删除临时钥匙串；GitHub 托管的运行机器也会被销毁。

## 发布一个版本

1. 在 Xcode 工程中设置正式版本号。应用 target 的 Debug 和 Release 中的 `MARKETING_VERSION` 应保持一致。
2. 审阅并将代码、发布流程和版本号提交、推送到 main。
3. 确认上述 GitHub 配置完成，再给这次提交打标签并推送。以下仅为当前工程 2.0.1 的命令示例：

~~~sh
git tag -a v2.0.1 -m "Tidest 2.0.1"
git push origin v2.0.1
~~~

推送标签会自动开始正式发布。无需先在 Releases 页面创建 Release，也不要先上传本地安装包。

流程要求标签使用 `v主版本.次版本.修订版本`，例如 `v2.0.1`，并与应用 Release 版本号一致；该提交必须已经包含在远端 main 中。构建编号使用 GitHub 的运行编号，重试同一次运行时保持不变。

在 **Actions → Release** 中查看进度。流程会：

1. 核对标签、源码提交、版本号和工具链，拒绝替换已有版本。
2. 使用 **Xcode 27.0 (27A266a)**，构建包含 arm64 和 x86_64 的应用。
3. 签名应用，提交 ZIP 给 Apple，等待通过后将公证票据附到应用上。
4. 将该应用和“应用程序”快捷方式装入 DMG；签名、公证并附上 DMG 票据。
5. 挂载最终 DMG，核对内部应用的签名和票据。
6. 生成文件指纹和构建信息，再用 GitHub 构建来源证明关联最终文件。
7. 创建草稿，上传全部附件，再下载一次验证文件内容和构建证明。
8. 发布草稿，等待 GitHub 生成发布证明，再验证不可变发布、全部附件及其构建来源。成功后，运行摘要中会显示下载链接。

发布证明由 GitHub 在发布后异步生成。流程先确认版本已公开且不可变，再每 10 秒查询一次证明，最多等待 120 秒。证明尚不存在（HTTP 404）或证明列表为空时才等待；权限、限流、网络、签名或文件验证出错会立即失败，不会因重试而跳过检查。

当前 `xcode-27` 是 GitHub 托管的预览运行环境标签；所用 Xcode 本身固定为正式版 27.0，和工程创建时使用的版本一致。实际运行环境、SDK 和 Xcode 版本都会写入构建信息；更新工具链需审阅流程和脚本后提交。

正式附件包括：

- `Tidest-X.Y.Z.dmg`：用户安装包。
- `BUILD-INFO.json`：源码提交、工具链、签名 Team ID、Apple 公证编号和 DMG 指纹。
- `SHA256SUMS`：DMG 和构建信息的 SHA-256 文件指纹。
- `provenance.sigstore.json`：GitHub 构建来源证明，可用于离线保存和后续验证。

构建日志和公证诊断保留在本次 Actions 的诊断附件中，保存 14 天；它们不是正式发布附件。

## 官网和更新接口的地址

`download_url` 使用带版本号的固定安装包直链。例如：

[Tidest 2.0.1 DMG](https://github.com/mixBayes/Tidest/releases/download/v2.0.1/Tidest-2.0.1.dmg)

这只是地址格式示例；对应版本发布后才可下载。GitHub 会重定向到文件存储服务，不需要用户先进入发布页面。官网更新与发布包是两个独立步骤，本流程不会自动修改官网或更新接口。

## 用户验证下载文件

以下以 `v2.0.1` 为例。需要安装支持 `gh release verify`、`gh release verify-asset` 和 `gh attestation verify` 的 GitHub CLI，并按 CLI 提示登录。

### 确认文件属于不可变发布

~~~sh
gh release verify v2.0.1 -R mixBayes/Tidest
gh release verify-asset v2.0.1 ./Tidest-2.0.1.dmg -R mixBayes/Tidest
~~~

第一个命令检查不可变发布的证明；第二个检查本地文件是否与该发布附件完全一致。GitHub 自动生成的 Source code ZIP/TAR 不属于这里验证的安装包附件。

### 确认公开源码与构建流程

从上述发布证明中核对完整源码提交 SHA，将下面的占位值替换为该 SHA：

~~~sh
EXPECTED_COMMIT_SHA='替换为已核对的完整源码提交SHA'
gh attestation verify ./Tidest-2.0.1.dmg \
  -R mixBayes/Tidest \
  --signer-workflow mixBayes/Tidest/.github/workflows/release.yml \
  --source-ref refs/tags/v2.0.1 \
  --source-digest "$EXPECTED_COMMIT_SHA" \
  --deny-self-hosted-runners
~~~

不应只根据同目录中一个未经验证的 BUILD-INFO.json 决定信任哪个提交。发布页的源代码链接可以用于审阅该提交的内容；正式附件中的 BUILD-INFO.json 本身也有构建证明。

将 `provenance.sigstore.json` 下载到同一目录后，可以在上述命令中增加 `--bundle ./provenance.sigstore.json` 来指定本地证明。完全离线验证还需要预先保存 Sigstore 信任根，详见 GitHub 官方文档。

### 确认 Apple 签名与公证

~~~sh
xcrun stapler validate ./Tidest-2.0.1.dmg
spctl --assess --type open --context context:primary-signature --verbose=4 ./Tidest-2.0.1.dmg
~~~

安装到“应用程序”后，可进一步检查：

~~~sh
codesign --verify --deep --strict --verbose=2 /Applications/tidest.app
codesign --display --verbose=4 /Applications/tidest.app
spctl --assess --type execute --verbose=4 /Applications/tidest.app
~~~

核对 Developer ID Application 身份及 TeamIdentifier 与预期开发者一致。Apple 公证不审核源码是否安全，也不证明它对应哪个公开提交；源码与构建的对应关系由 GitHub 构建证明、公开构建步骤及其受信任运行环境共同提供。

这些证明不能替代源码审阅，也不承诺任何人重新编译都能得到逐字节相同的签名 DMG。

## 单独复核已发布的版本

在 **Actions → Verify release → Run workflow** 中选择 **main**，填写已发布的标签（例如 `v2.0.4`），运行验证。

这个流程会下载原始附件，核对发布证明、四个附件的文件指纹、构建来源对应的标签和源码提交，以及 DMG 的 Apple 公证。它只有读取权限，不使用签名凭据，不会重新打包、发布、覆盖附件或移动标签，也不受当前应用版本号限制。

验证结果记录在这次 **Verify release** 运行中。以前失败的发布运行仍会保留原来的红色状态，独立验证不会改写历史。

## 失败后处理

- 编译、签名、公证或证明验证失败：流程停止发布，在 Actions 中查看失败步骤和诊断附件。
- Apple 公证等待超时：提交可能仍在处理，诊断文件中的提交编号可用于查询；本次流程不会发布未经确认的包。
- 已创建草稿但上传或复核失败：删除这个未发布草稿后，使用原标签重新运行失败的工作流。不要移动标签来改变源码。
- 已发布但等待发布证明超时：稍后运行 **Verify release** 复核已有附件，不要重新运行打包发布流程。
- 已发布但不可变验证失败：查看具体错误，并运行 **Verify release** 复核。如果漏开 Enable release immutability，该设置不能追溯保护旧发布，需要以新的版本号重新发布；签名或文件不匹配也不能跳过验证。
- 已成功发布的安装包需要修复：修改源码并使用新版本号，不能覆盖旧附件。

## 本地检查

发布证明等待与失败处理的回归检查：

~~~sh
python3 scripts/tests/test_verify_release.py
~~~

不需要证书即可验证版本号、工具链和通用版本编译：

~~~sh
bash scripts/release.sh check v2.0.1
RELEASE_WORK_DIR=/tmp/tidest-release-check bash scripts/release.sh build v2.0.1
RELEASE_WORK_DIR=/tmp/tidest-release-check bash scripts/release.sh smoke-dmg v2.0.1
~~~

每次使用一个新的输出目录。smoke-dmg 仅检查本地打包，生成的包未经过正式签名、公证或构建证明，不能作为正式安装包分发。

## 官方参考

- [GitHub 不可变发布](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
- [开启不可变发布](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes)
- [构建来源证明](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations)
- [GitHub CLI 验证选项](https://cli.github.com/manual/gh_attestation_verify)
- [Apple 自动公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
