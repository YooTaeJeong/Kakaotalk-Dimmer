# Kakaotalk Dimmer

Made by Hyeonseop Lee, Taejeong Yoo

카카오톡(PC) 창이 너무 밝아서 눈이 피로할 때, 화면 위에 반투명한 검은 오버레이를 씌워 밝기를 낮춰주는 Windows용 트레이 유틸리티입니다.

카카오톡 실행 파일 자체를 수정하지 않고, 별도의 오버레이 창을 카카오톡 위에 겹쳐서 밝기만 낮춥니다. 클릭/입력은 그대로 카카오톡에 전달되므로 사용에는 지장이 없습니다.

## 주요 기능

- **자동 감지**: 카카오톡 창이 화면에 보이는 동안 자동으로 오버레이를 씌우고, 최소화/종료 시 자동으로 사라집니다.
- **밝기 조절**: 트레이 아이콘 우클릭 → **밝기** 메뉴에서 0%(끄기) ~ 90%까지 10% 단위로 조절할 수 있습니다.
- **반응 속도 조절**: 트레이 아이콘 우클릭 → **반응속도** 메뉴에서 창을 얼마나 빠르게 따라갈지 조절합니다 (8ms ~ 100ms).
- **다른 창을 가리지 않음**: 다른 프로그램 창이 카카오톡 위에 떠 있으면, 그 창과 겹치는 부분은 자동으로 잘라내어 다른 앱을 어둡게 가리지 않습니다.
- **상태 표시 아이콘**: 트레이 아이콘이 현재 밝기 단계에 따라 색이 바뀝니다 (밝은 호박색 → 짙은 남색).
- **설정 자동 저장**: 밝기/반응속도 설정은 `%APPDATA%\KakaoDarkOverlay\settings.txt`에 저장되어 다음 실행 시 그대로 유지됩니다.

## 사용법

1. [`run-kakao-dark-overlay.vbs`](run-kakao-dark-overlay.vbs)를 더블클릭합니다. (콘솔 창 없이 조용히 트레이 아이콘만 나타납니다)
2. 작업표시줄 우측 하단 트레이 아이콘을 우클릭하여 밝기와 반응속도를 조절합니다.
3. 끄고 싶을 때는 트레이 메뉴에서 **종료**를 클릭합니다.

### Windows 시작 시 자동 실행 등록

`Win + R` → `shell:startup` 입력 후, `run-kakao-dark-overlay.vbs`의 바로가기를 그 폴더에 추가하면 로그인할 때마다 자동으로 실행됩니다.

## 요구 사항

- Windows 10/11
- Windows PowerShell 5.1 (Windows에 기본 내장되어 있어 별도 설치 불필요)

## 동작 방식 (간단히)

- Win32 API(`EnumWindows`, `GetWindowRect` 등)로 화면에 보이는 모든 창을 z-order(쌓임 순서) 순으로 확인합니다.
- 그중 카카오톡(`KakaoTalk.exe`) 프로세스 소유의, 일정 크기(`-MinWindowSize`, 기본 300px) 이상인 창을 찾아 그 위치/크기에 맞춰 반투명 검은 오버레이(Layered Window)를 씌웁니다.
- 오버레이보다 z-order상 위에 있는(=더 앞에 떠 있는) 다른 창과 겹치는 영역은 `SetWindowRgn`으로 잘라내어, 카카오톡 창이 다른 창에 가려진 부분까지 어둡게 칠하지 않도록 합니다.
- 오버레이 창은 `WS_EX_TRANSPARENT | WS_EX_NOACTIVATE`로 생성되어 클릭/포커스를 가로채지 않습니다.

## 스크립트 옵션

`kakao-dark-overlay.ps1`은 다음 파라미터를 지원합니다 (PowerShell에서 직접 실행 시):

| 파라미터 | 기본값 | 설명 |
| --- | --- | --- |
| `-MinWindowSize` | `300` | 이 크기(px)보다 작은 창은 무시합니다 (숨김 헬퍼 창 제외용) |
| `-DisableClipping` | off | 다른 창과 겹치는 부분을 잘라내는 기능을 끕니다 |
| `-DebugClipping` | off | 어떤 창과 겹쳐서 잘렸는지 콘솔에 출력합니다 (디버그용) |

```powershell
powershell -NoProfile -File .\kakao-dark-overlay.ps1 -MinWindowSize 200 -DebugClipping
```

## 알려진 제한 사항

- 카카오톡 창을 매우 빠르게 움직이거나 리사이즈하면, 반응속도 설정 간격만큼 아주 짧게 오버레이가 늦게 따라올 수 있습니다.
- `-MinWindowSize`보다 작은 팝업(이모티콘 선택창 등)은 오버레이 대상에서 제외됩니다.

## 라이선스

MIT License (저장소에 `LICENSE` 파일 참고)
