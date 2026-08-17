# FFXIV on Mac KR

한국 FINAL FANTASY XIV 클라이언트를 Apple Silicon Mac에서 실행하기 위한
비공식 네이티브 런처입니다.

- 한국 공식 런처 페이지를 이용한 액토즈 계정 로그인
- 공식 파일 목록을 이용한 설치와 ZiPatch 업데이트
- 독립 XIV on Mac 런타임 사용—CrossOver 불필요
- 다운로드 진행률과 Dock 진행률 표시

현재 앱은 개인용 실험 버전이며 서명·공증되지 않았습니다. Apple Silicon
Mac만 지원합니다.

## 빌드

```sh
swift test --disable-sandbox
scripts/package.sh
```

게임 시작 버튼을 표시하기 전에 같은 업데이트 화면에서
`softwareupdate.xivmac.com`의 공식 XIV on Mac 런타임을 직접 내려받고,
고정된 SHA-256 검증·압축 해제·prefix 초기화·DXMT 및 `d3dcompiler_47.dll`
설치까지 완료합니다.

이 프로젝트는 GPL-3.0으로 배포합니다. 외부 구성요소에는 각 구성요소의
라이선스가 적용됩니다. FINAL FANTASY XIV는 Square Enix의 상표이며, 이
프로젝트는 Square Enix·액토즈소프트·CodeWeavers·XIV on Mac과 관련 없는
비공식 프로젝트입니다.
