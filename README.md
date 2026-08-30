# AnkiNotes - 基于笔记的间隔重复记忆应用

> 把你的 Markdown 笔记变成可复习、可刷题的知识卡片，用 AI 自动生成题目，用间隔重复算法对抗遗忘。

![iOS](https://img.shields.io/badge/iOS-16.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![SwiftUI](https://img.shields.io/badge/SwiftUI-3.0-green)
![License](https://img.shields.io/badge/license-MIT-purple)

---

## ✨ 核心特性

### 📝 笔记管理

- **文件夹层级管理**：支持多级文件夹，递归统计笔记数量
- **Markdown 编辑与渲染**：原生 Markdown 渲染，支持表格、代码块等格式
- **智能搜索**：搜索框实时下拉建议，高亮匹配字符，点击跳转详情
- **笔记状态标识**：新增笔记显示"新"标识，已生成题目的笔记显示"题"标识
- **无限滚动加载**：默认显示 10 条，下滑自动加载更多

![笔记管理界面](Screenshot/笔记.jpg)

### ☁️ WebDAV 云端同步

- **协议支持**：标准 WebDAV 协议，兼容坚果云、Nextcloud、群晖等
- **双向同步**：本地和云端双向同步，新增/修改/删除均同步
- **文件夹结构同步**：保持云端文件夹结构，按目录整理笔记
- **后台静默同步**：每次打开应用后台自动静默同步
- **防冲突机制**：编辑前单独同步该笔记，减少冲突概率
- **同步锁**：同步操作加锁，防止重复执行

### 🧠 间隔重复复习

- **SRS 算法**：基于 SM-2 的间隔重复算法，智能调整复习间隔
- **四级评级**：极难 / 困难 / 良好 / 简单，最小复习间隔 1 天
- **做题测评评级**：已生成题目的笔记可通过做题自动评估掌握程度
- **预计用时估算**：按笔记字数智能估算复习用时，不再离谱
- **按文件夹复习**：可选择特定文件夹进行针对性复习
- **今日概览**：待复习 / 新笔记 / 学习中 / 已复习 统计一目了然
- **连续打卡**：记录连续学习天数，激励坚持

![复习界面](Screenshot/复习.jpg)

### 🤖 AI 题库生成

- **百炼大模型接入**：接入阿里云百炼平台，支持自定义 API Key 和模型
- **自动生成题目**：按笔记内容自动生成选择题和填空题，覆盖所有知识点
- **流式生成**：SSE 流式响应，边生成边显示进度，不再超时
- **逐篇保存**：每完成一篇笔记立即保存，意外中断不丢失已生成题目
- **可中途取消**：生成过程中可随时取消，不影响已生成题目
- **报错提示**：生成失败时弹出具体错误原因，便于排查

### 🎯 刷题系统

- **智能选题算法**：随机抽题但保证公平，错题和未做题优先，做对的题概率更低
- **题库统计**：未作答 / 答对 / 答错 / 选择题 / 填空题 / 正确率 全方位统计
- **多种题量**：支持 5 / 10 / 20 / 30 / 50 题自选
- **答案解析**：每题提供参考答案和详细解析
- **下拉刷新**：刷题菜单支持下拉刷新题库统计

![刷题界面](Screenshot/刷题.jpg)

### 📖 做题体验

- **选择题**：点击选项即时判分，正确答案绿色高亮
- **填空题**：输入答案提交，支持多个可接受答案
- **即时反馈**：回答正确/错误即时提示，显示参考答案和解析
- **进度显示**：顶部显示当前题号/总题数
- **来源标注**：显示题目来源笔记标题

![做题界面](Screenshot/做题.jpg)

---

## 🚀 安装方式

### 方式一：GitHub Actions 自动编译 IPA（推荐）

本项目配置了 GitHub Actions 自动编译流程，推送代码即可自动编译 IPA。

1. **Fork 本仓库**到你的 GitHub 账号
2. **配置代码签名**（如需安装到真机）：
   - 在 GitHub 仓库 Settings → Secrets and variables → Actions 中配置：
     - `IOS_CODE_SIGN_IDENTITY`：代码签名身份
     - `IOS_PROVISIONING_PROFILE`：描述文件
     - `IOS_TEAM_ID`：开发团队 ID
     - `IOS_CERTIFICATE`：证书（base64 编码）
     - `IOS_CERTIFICATE_PASSWORD`：证书密码
3. **推送代码**触发自动编译（commit 消息包含 `[build-ipa]`）
4. **下载 IPA**：进入仓库 Actions 页面，找到最新的构建记录，拉到最底部 Artifacts 区域下载 `AnkiNotes-Device-IPA`
5. **侧载到 iPhone**：使用 [SideStore](https://sidestore.io/) 或 [AltStore](https://altstore.io/) 将 IPA 安装到 iPhone

### 方式二：本地编译

**环境要求**：
- macOS 13+
- Xcode 15+
- Apple 开发者账号（免费账号也可，7 天证书有效期）

**步骤**：
```bash
# 1. 克隆仓库
git clone https://github.com/Han03/AnkiNotes.git
cd AnkiNotes

# 2. 打开 Xcode 项目
open AnkiNotes.xcodeproj

# 3. 在 Xcode 中配置签名：
#    - 选择项目 → Signing & Capabilities
#    - 选择你的开发团队
#    - 修改 Bundle Identifier 为唯一值

# 4. 连接 iPhone，选择设备，点击运行
```

---

## ⚙️ 配置说明

### WebDAV 同步配置（以坚果云为例）

1. 登录[坚果云网页版](https://www.jianguoyun.com/)
2. 右上角头像 → **账户信息** → **安全选项**
3. 在**第三方应用管理**中点击**添加应用**，输入应用名称（如 AnkiNotes），生成密码
4. 打开 AnkiNotes App → **设置** → **WebDAV 同步**
5. 填写配置：
   - **服务地址**：`https://dav.jianguoyun.com/dav/`
   - **用户名**：你的坚果云账号（邮箱）
   - **密码**：刚才生成的第三方应用密码
   - **远端根目录**：`/AnkiNotes`（自定义）
6. 点击**测试连接**，成功后保存配置

### 百炼大模型配置

1. 登录[阿里云百炼平台](https://bailian.console.aliyun.com/)
2. 创建 API Key（API-KEY 管理 → 创建新的 API-KEY）
3. 选择模型（推荐 `qwen-turbo` 或 `qwen-plus`）
4. 打开 AnkiNotes App → **设置** → **大模型题库设置**
5. 填写：
   - **API Key**：刚才创建的 API Key
   - **模型编码**：如 `qwen-turbo`
6. 进入**刷题**菜单，点击**生成题目**，AI 将自动为所有笔记生成题目

---

## 🛠️ 技术栈

| 类别 | 技术 |
|------|------|
| 语言 | Swift 5.9 |
| UI 框架 | SwiftUI |
| 最低系统 | iOS 16.0 |
| 数据存储 | JSON 文件 +本地缓存 |
| 云端同步 | WebDAV 协议 |
| AI 接口 | 阿里云百炼 API（OpenAI 兼容模式，SSE 流式） |
| 记忆算法 | SM-2 间隔重复算法 |
| CI/CD | GitHub Actions（自动编译 IPA） |

---

## 📁 项目结构

```
AnkiNotes/
├── AnkiNotes/
│   ├── Models/                    # 数据模型
│   │   ├── Note.swift             # 笔记模型
│   │   ├── Folder.swift           # 文件夹模型
│   │   ├── Question.swift         # 题目模型
│   │   ├── SRSData.swift          # SRS 记忆数据
│   │   └── ...
│   ├── Views/                     # 界面
│   │   ├── FolderBrowserView.swift  # 笔记浏览
│   │   ├── NoteDetailView.swift      # 笔记详情
│   │   ├── ReviewHomeView.swift      # 复习主页
│   │   ├── ReviewSessionView.swift   # 复习会话
│   │   ├── ReviewQuizView.swift      # 做题测评
│   │   ├── QuizHomeView.swift        # 刷题主页
│   │   ├── QuizSessionView.swift     # 刷题会话
│   │   ├── SettingsView.swift        # 设置
│   │   └── ...
│   ├── Services/                  # 业务逻辑
│   │   ├── StorageService.swift      # 本地存储
│   │   ├── WebDAVService.swift       # WebDAV 同步
│   │   ├── SchedulerService.swift    # SRS 调度算法
│   │   ├── QuizService.swift         # 题库生成与管理
│   │   └── ...
│   ├── Assets.xcassets/           # 资源文件
│   └── AnkiNotesApp.swift         # 应用入口
├── Screenshot/                    # 应用截图
├── .github/workflows/             # GitHub Actions 配置
│   └── build-ipa.yml              # IPA 自动编译流程
└── README.md
```

---

## 📊 记忆算法说明

本应用采用基于 **SM-2** 的间隔重复算法，根据用户对笔记的掌握程度自动调整下次复习时间。

### 评级与复习间隔

| 评级 | 说明 | 首次复习 | 后续复习间隔 |
|------|------|----------|--------------|
| 极难 | 完全没掌握 | 1 天 | 间隔增长缓慢 |
| 困难 | 勉强记得 | 1 天 | 间隔正常增长 |
| 良好 | 基本掌握 | 1 天 | 间隔较快增长 |
| 简单 | 完全掌握 | 4 天 | 间隔快速增长 |

> 所有评级的最小复习间隔为 1 天，避免当天重复看同一篇长笔记，降低学习积极性。

### 做题测评

对于已生成题目的笔记，可选择"测评"按钮，通过做题自动评估掌握程度：
- 正确率 ≥ 90% → 简单
- 正确率 70-89% → 良好
- 正确率 40-69% → 困难
- 正确率 < 40% → 极难

---

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启 Pull Request

---

## 📄 许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件。

---

## 🙏 致谢

- [阿里云百炼平台](https://bailian.console.aliyun.com/) - 大模型 API
- [SideStore](https://sidestore.io/) / [AltStore](https://altstore.io/) - IPA 侧载工具
- 所有为这个项目贡献代码和建议的开发者
