# photo_manager_video_player

> **상태: 설계 단계.** 코드는 아직 없다. 시작점 문서는
> [`docs/proposal.md`](docs/proposal.md).

`photo_manager`의 `AssetEntity`를 **원본 복사 없이** 재생하는 컴패니언 패키지.

```dart
// 지금 (원본을 앱 샌드박스로 복사한 뒤에야 재생이 시작된다)
final file = await entity.file;              // Android: 전체 복사 / iOS: export
final controller = VideoPlayerController.file(file!);

// 이 패키지가 목표하는 것 (복사 0바이트)
final controller = GalleryVideoController.fromAsset(entity);
```

| | Android | iOS |
|---|---|---|
| 해석 | MediaStore `content://` URI | `PHImageManager.requestPlayerItem` |
| 재생 | ExoPlayer | `AVPlayer(playerItem:)` |
| 원본 복사 | **없음** | **없음** |
| 추가 프레임워크 | 없음 | `Photos.framework` |

## 왜 별도 패키지인가

범용 플레이어(`video_player`, `native_video_player`)는 iOS에서 `Photos.framework`를
링크할 수 없다 — 링크하는 순간 그 플러그인을 쓰는 **모든 앱**이
`NSPhotoLibraryUsageDescription`을 요구받는다. 그래서 이 문제는 구조적으로
갤러리 쪽 패키지에서만 풀 수 있다.

`photo_manager` 생태계에는 이미 같은 패턴의 선례가 있다 —
[`flutter_photo_manager_plugins`](https://github.com/fluttercandies/flutter_photo_manager_plugins):

```
packages/
├── photo_manager_image_provider   이미지 위젯 통합
├── photo_manager_location         CoreLocation 분리
└── (photo_manager_video_player)   ← 비어 있는 자리
```

자세한 논거와 기술 근거는 [`docs/proposal.md`](docs/proposal.md).

## 라이선스

미정 (업스트림 합류를 고려해 Apache-2.0 예정).
