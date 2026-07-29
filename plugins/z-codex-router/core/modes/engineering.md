# Engineering

## 适用范围

源码、测试、脚本、必要项目配置、缺陷修复、功能、重构和性能工作。对编程开发人员的适用度为高，覆盖服务端、Web/客户端与移动端；agent 仍按能力与权限边界分工，不按职业逐一新增。

本 mode 只提供工程任务的映射示例；Tier 仍按 router 的统一判定轴和顺序决定。

## 任务类型到 Tier

| 任务 | Tier |
| --- | --- |
| 已知路径的只读或不产生持久副作用的固定检查 | A0 |
| 根因明确的局部、可逆修复 | A1 |
| 文件、边界和验收明确的中型多步实现 | B0 |
| 根因和边界明确的大型多文件实现 | B1 |
| 多模块状态、异步/并发、性能、视频管线或平台差异 | B2 |
| 根因未知、架构取舍、核心能力或迁移方案 | C1 |
| 短提示、范围较大、需要自主定位和设计的长周期工程 | C2 |
| 登录、支付、用户数据、迁移/导出正确性、生产风险或一次成功率优先 | C3 |

## 检查与验收证据

先区分“明确执行”与“自主探索”：前者按 A1/B0/B1/B2 路由，后者按 C1/C2/C3 路由。确认现有实现、受影响接口/API/schema contract、数据迁移/事务/一致性、鉴权与威胁边界、并发/队列/缓存、可观测性、容量/性能基线，以及部署、灰度与回滚边界。检查正向、失败和边界路径，以及资源、权限、线程、生命周期和平台约束；视频还检查输入、管线、codec、像素格式、色彩、time base、帧率、旋转、HDR 与 A/V sync。验收为最小 diff、静态/格式检查及与改动相称的 focused tests；性能声明需要可比基线。

### Backend / Service

确认 API/schema contract、数据库迁移与事务、幂等/一致性、鉴权、队列/任务、缓存、并发、容量/负载、日志/指标/trace、部署/canary/回滚，以及备份恢复；生产副作用和迁移按风险提升并要求明确授权。

### Web Frontend

实现类 Web 前端任务以 Engineering 为主，必要时以 Design 作为视觉、交互或设计源辅助；focused tests 仍由 Engineering 负责，实际浏览器交互、运行界面逐项 QA、GUI 和完整构建按既有规则交给 `runtime_validator`。不得把单一浏览器的本地开发结果当作兼容性结论。

确认运行目标与证据范围：目标浏览器及版本、渲染引擎、视口/设备、输入方式（鼠标、键盘、触控等）和网络条件；明确哪些目标未运行、未覆盖或仅静态检查。记录 HTML/CSS/JavaScript/TypeScript 的实际使用情况、框架及版本（React、Vue、Svelte、Angular 等仅为非穷举示例，不得假设项目采用）、package manager、lockfile、bundler/build tool、环境变量和开发/测试/生产构建模式。

核对项目实际采用的 CSR、SSR、SSG 或混合渲染，不臆造框架能力；检查 routing、hydration、state、data fetching/cache、表单提交与校验，以及加载、错误、空、离线/重试和失败边界状态。确认服务端数据、鉴权和 API contract 的责任边界，避免以客户端校验或隐藏 UI 代替服务端安全控制。

以项目设计源、组件和 token 为准核对视觉 UI：响应式容器与断点、主题/暗色、字体与媒体加载、交互/动画、`prefers-reduced-motion` 和所有状态。实现与设计源逐项比对；视觉回归和运行界面逐项 QA 必须有实际证据，不以截图或静态检查声称运行通过。

检查可访问性：语义 HTML、键盘顺序与操作、可见焦点、屏幕阅读器名称/状态/提示、对比度、文本与页面缩放、错误关联和必要的 ARIA。ARIA 仅在需要时使用，不能替代语义结构；组件状态和动态更新也要能被辅助技术感知。

按目标产品定义并记录性能预算与真实测量，覆盖加载、交互响应、布局稳定性、bundle 体积、图片/字体、缓存/CDN；若使用 Web Vitals，只引用当前项目或官方定义，不硬编码通用阈值。区分本地开发、测试构建与生产网络条件，报告测量方法、基线和未测项目。

核对 Web 安全与隐私：XSS、CSRF、CSP、CORS、cookie/session 属性、敏感数据暴露、第三方脚本和依赖供应链；清楚区分前端可控项与服务端/平台责任，不把客户端过滤、CORS 配置或构建时变量当作机密保护。

按项目实际栈选择并记录 unit/component/integration/E2E、visual regression、跨浏览器、SSR/hydration、失败与边界路径测试；不能把未运行的命令写成通过，实际浏览器交互证据须注明浏览器、版本、设备/视口和网络条件。兼容性结论只覆盖已执行的矩阵。

检查发布与运维链路：source map 的生成、上传和访问控制，错误/性能监控，feature flag，缓存/CDN 失效，灰度、回滚和版本关联。PWA、service worker、离线缓存仅在项目实际采用时检查，不能因存在前端构建而默认要求。

### Mobile 共通

明确目标 OS、设备与 API 级别、依赖与构建工具链、权限/隐私、生命周期/后台限制、网络与离线、状态恢复、线程/并发、性能/电量/内存、深链/推送、国际化/无障碍、签名/证书、包格式、升级兼容、崩溃监控、商店/分发与回滚。GUI、设备、模拟器和完整构建仍由 `runtime_validator` 串行执行，不能以静态检查替代。

移动 UI/排版验收以设计源、组件与 token、字体文件/授权及运行时实际加载证据为准：核对 `font family`/fallback、字号、字重、行高、字距、换行、截断与溢出，并覆盖文字缩放、locale/多语言和无障碍。验证字体文件实际支持所声明的 weight，避免缺失字重被 synthetic/bold fallback 或平台差异掩盖。测量水平/垂直对齐、文本基线、文字与图标基线、容器居中、padding/content inset、安全区、网格/间距 token、相邻元素间距、密度/逻辑单位与多屏适配；不能以“看起来居中”代替布局约束或测量证据，同时校正文本 line metrics、内边距和基线造成的视觉偏移。

### Flutter

核对项目实际 Dart/Flutter SDK 与 channel、pub 依赖、widget 与生命周期、isolate/async、state restoration、flavor、platform channel/plugin。适用时检查 `TextStyle` 的 family/size/weight/height/letterSpacing、字体 assets 与 `pubspec.yaml` 声明、fallback，以及 `TextAlign`、`Alignment`、`MainAxisAlignment`/`CrossAxisAlignment`、`Baseline`、`Padding`、`SafeArea`、`LayoutBuilder`、文字缩放和可访问性；这些 API 名称只是检查入口，最终以实际布局约束、测量和渲染证据为准。golden/截图测试固定或记录字体、locale、theme、text scale、surface size、device pixel ratio 和平台；golden 只能证明已覆盖该配置，不能替代真机/模拟器及多平台视觉 QA。platform channel/plugin 或不同渲染、字体栅格化差异不得被单平台结果掩盖。
对 Android、iOS、HarmonyOS 的目标实际支持边界逐项确认；不得因 Flutter 或插件存在而假设某平台可构建、可运行或支持所有能力。

实现类任务以 Engineering 为主，Design 提供设计源/规范辅助；GUI、设备、模拟器、完整构建和跨平台实际视觉 QA 由 `runtime_validator` 串行执行。未实际运行时，不声称高还原或跨平台通过。

### Android

核对 Kotlin/Java、Gradle/AGP/JDK、manifest/permission、Activity/Fragment/Compose 生命周期、后台限制、API/ABI、签名、APK/AAB、测试与发布链路。

### iOS

核对 Swift/Objective-C、SwiftUI/UIKit、Xcode/SDK、SPM/CocoaPods、entitlement/capability、签名/provisioning、app extension、并发/生命周期、archive/TestFlight/App Store、测试与回滚链路。

### HarmonyOS NEXT

以华为官方一手开发文档为准，核对 ArkTS、ArkUI、DevEco Studio、HarmonyOS SDK/API、Stage 模型、UIAbility/ExtensionAbility、`module.json5`/权限、HAP 与 APP Pack（Application Package）、签名、真机/模拟器、分发与兼容。不要将 HarmonyOS NEXT 的原生工程、构建和运行模型与 Android 兼容层混为一谈；术语、SDK/API 或包格式有变化或不确定时，先浏览官方文档再作结论。

## 环境阻塞

缺少可复现步骤、依赖、SDK、目标平台、测试数据、签名材料或权限时，记录未验证项；Web 任务还要明确缺少目标浏览器矩阵、设计源、构建依赖、后端/认证环境、测试账号或可运行环境的影响。移动/Flutter 任务还要明确缺少设计源、字体资源或授权、组件/token、目标设备/屏幕矩阵、locale、文字缩放设置或可运行界面的影响。GUI、设备、模拟器、完整构建和跨端验证另受运行环境约束。未实际完成平台构建、浏览器交互或真机/模拟器验证时，不声称已验证发布、性能、视觉或兼容性。
