# 书阅读 (BookReader)

iOS 电子书语音阅读应用，支持 TTS 朗读。

## 功能特性

- **书架管理** - 展示和管理已导入的电子书
- **多格式支持** - TXT, EPUB, PDF
- **TTS 语音朗读** - 使用 Apple Neural Engine 加速的高质量语音
- **阅读进度同步** - 自动记录每本书的阅读/播放位置
- **语速/音调调节** - 0.5x - 2.0x 语速可调
- **语音选择** - 支持中英文多种语音

## 项目结构

```
BookReader/
├── project.yml                 # XcodeGen 配置
├── .github/
│   └── workflows/
│       └── ios-build.yml       # GitHub Actions 自动编译
├── Sources/
│   ├── App/
│   ├── Models/
│   ├── Views/
│   ├── ViewModels/
│   ├── Services/
│   ├── Database/
│   └── Extensions/
└── Resources/
    └── Assets.xcassets/
```

## 本地开发（需要 Mac）

### 环境要求

- macOS
- Xcode 15.0+
- XcodeGen (`brew install xcodegen`)

### 安装步骤

```bash
cd BookReader
xcodegen generate
open BookReader.xcodeproj
```

在 Xcode 中选择设备并运行。

## GitHub Actions 自动编译（无需 Mac）

### 快速开始

1. **Fork 此仓库**

2. **推送代码到 main 分支**
   ```bash
   git init
   git add .
   git commit -m "Initial commit"
   git remote add origin https://github.com/YOUR_USERNAME/BookReader.git
   git push -u origin main
   ```

3. **查看 Actions**
   - 访问 `https://github.com/YOUR_USERNAME/BookReader/actions`
   - 每次 push 会自动触发编译

### 工作流说明

| 工作流 | 触发条件 | 说明 |
|--------|----------|------|
| `build` | push/PR | 构建 Debug 版本到模拟器 |
| `archive-only` | push/PR | 生成 Release .xcarchive |

### 下载编译产物

1. 进入 Actions 页面
2. 点击任一 workflow run
3. 在 Artifacts 部分下载 `build-artifacts` 或 `ios-archive`

### 生成的 .xcarchive 有什么用？

.xcarchive 包含编译好的 iOS 应用，但：
- **无法直接安装到 iPhone**（需要签名证书）
- **可以用于**：
  - 代码签名检查
  - 作为 CI 验证手段
  - 配合 Apple Developer 账号导出签名

### 如需生成可安装的 .ipa

需要在仓库 Secrets 中配置：
- `APPLE_CERTIFICATE` - P12 证书
- `APPLE_PROFILE` - Provisioning Profile

详细配置见：
[GitHub Actions iOS Starter Workflow](https://github.com/actions/starter-workflows/blob/main/ios/ios-swift-xcode.yml)

## 依赖

| 包 | 版本 | 用途 |
|----|------|------|
| SQLite.swift | 0.14.1+ | 数据存储 |

## License

MIT