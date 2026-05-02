導航管家 Pro V9.1 Flutter 真機功能版

這版已接入：
- 真 GPS 定位：geolocator
- 相機錄影：camera
- 哪吒語音播報：flutter_tts
- 語音輸入：speech_to_text
- 急煞/震動感測：sensors_plus
- 權限處理：permission_handler
- 影片儲存：path_provider/path

老闆版：
- 無登入
- 無授權
- 無限制

重要：
這是 Flutter 原生 Android 專案骨架，不是 Netlify/PWA。
需要用 Flutter 真機環境打包和測試，錄影、定位、語音都必須在 Android 手機上測。

打包方式：
1. 安裝 Flutter SDK
2. 解壓縮此 ZIP
3. 進入資料夾執行：flutter create .
4. 執行：flutter pub get
5. 接手機或用雲端 CI 打包
6. 執行：flutter build apk --release
7. APK 位置：build/app/outputs/flutter-apk/app-release.apk

注意：
- 第一次開啟會要求定位、相機、麥克風權限
- 相機錄影功能需要真機測試
- 語音辨識需要手機支援 Google 語音服務或系統語音服務
- 感測器急煞門檻可再依實測調整
