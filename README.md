# 准时吃饭打卡 · GitHub Pages + Supabase 免费版

这个仓库用于：

- GitHub Pages 免费托管网页
- Supabase Free 同步账号、打卡、奖励、补签、家务和私密照片
- GitHub Actions 自动构建 Android APK
- 上传照片前自动压缩：最长边约 1280px，目标约 240KB，通常不超过约 300KB

## 当前 Supabase
前端已经预置 Publishable Key 和 Project URL，不需要再手填。后端数据库、RLS、私密 `checkin-photos` Bucket 已经初始化完成。

## 上传到 GitHub 后
第一次提交到 `main` 后会自动运行两个 Actions：

1. `Deploy GitHub Pages`：构建并发布网页版。
2. `Build Android APK`：生成 `meal-stamp-debug-apk` Artifact，里面是 `app-debug.apk`。

如果 Pages 首次部署被 GitHub 要求确认，可进入仓库 `Settings → Pages`，把 Source 设为 `GitHub Actions`，然后重新运行 `Deploy GitHub Pages`。

## 安全
这里只包含 Supabase 的 Publishable Key，它本来就是给浏览器和 App 使用的公开客户端 Key。没有 service role、Secret Key 或数据库密码。真正的数据访问由 Supabase RLS 控制。
