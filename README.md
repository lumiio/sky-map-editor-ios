# Sky 地图编辑器 · iOS 原生版（Swift + Metal）

按 [Sky_Map_Editor_0318](https://github.com/XianXiaoWei/Sky_Map_Editor_0318) 的 TypeScript/C++ 源码为基准，重写的 iOS 原生实现。渲染走 Metal，解析走 Swift，不复用旧版 iOS 代码。

## 进度

- [x] 工程骨架 + CI 出未签名 ipa
- [ ] TGCL / LVL0 / 地形解析
- [ ] Metal 地形与对象渲染
- [ ] 导入 Data、对象树、编辑与保存

## 构建

推送到 `main` 后 GitHub Actions（macos-15）编译 Metal、生成工程并出 `SkyMapEditor-unsigned.ipa` 工件，需自行签名安装。
