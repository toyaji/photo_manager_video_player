# photo_manager_video_player — 제안서 겸 작업 시작점

> 이 문서는 **설계·구현 세션의 출발점**이다. 2026-09-02 조사에서 확인한 사실만 담았고,
> 추측은 "미확인"으로 표시했다. 근거 링크는 각 절 끝에 있다.

---

## 1. 한 문장

`photo_manager`의 `AssetEntity`(사진 라이브러리 영상)를 **원본 복사 없이** 재생하는
컴패니언 패키지. Android는 MediaStore `content://`를, iOS는 PhotoKit이 건네주는
`AVPlayerItem`을 그대로 플레이어에 물린다.

---

## 2. 지금 사용자들이 겪는 문제

`photo_manager`로 갤러리 영상을 재생하려면 현재는 이 방법뿐이다:

```dart
final file = await entity.file;
final controller = VideoPlayerController.file(file!);
await controller.initialize();
```

`entity.file`이 실제로 하는 일:

| 플랫폼 | 동작 | 근거 |
|---|---|---|
| **Android (API 29+)** | `shouldUseScopedCache`면 `scopedCache.getCacheFileFromEntity()` — **앱 캐시로 원본 전체 복사** | `android/.../core/utils/AndroidQDBUtils.kt:301-310` |
| **iOS / macOS** | `exportAssetToFile` → `AVAssetExportSession` **export** (결과는 디스크 캐시됨) | `ios/.../core/PMManager.m:761-776` |

즉 **재생이 시작되기 전에 파일 하나를 통째로 복사/인코딩해야 한다.** 200MB 영상이면
200MB를 복사한다. 갤러리처럼 **빠르게 스와이프하며 훑는 UX에서는 이 비용이 그대로
체감 지연**이 되고, 취소·디스크 정리·동시 실행 상한 같은 부수 문제를 계속 만든다.

`photo_manager`는 이 사실을 문서에 명시하고 있다:

> "File retrieving and caches are limited by the sandbox mechanism on iOS...
> When you call I/O methods, the resource will first cache into the sandbox,
> then become available for obtain."

이건 `photo_manager`의 결함이 아니라 **파일 API의 정직한 계약**이다.
문제는 **재생에는 파일이 필요 없다**는 것이다.

---

## 3. 복사하지 않는 길은 이미 OS에 있다

### 3.1 Android — 이미 열려 있다

| API | 반환 | 복사 |
|---|---|---|
| `entity.file` | 앱 캐시 파일 경로 | 전체 복사 |
| `entity.getMediaUrl()` | `content://media/external/video/media/894857` | **0 바이트** |

`getMediaUrl()`은 `IDBUtils.getMediaUri()`가 URI를 문자열로 돌려줄 뿐이다
(`IDBUtils.kt:510`). ExoPlayer는 `content://`를 네이티브로 재생한다.
`video_player`에도 이미 **Android 전용** 생성자가 있다:

```dart
VideoPlayerController.contentUri(Uri.parse(await entity.getMediaUrl()));
// video_player-2.11.1/lib/video_player.dart:473
```

**Android는 추가 프레임워크도, 추가 권한도 필요 없다.**

### 3.2 iOS — PhotoKit이 주는 객체를 그대로 써야 한다

정석은 이것이다:

```objc
[PHImageManager.defaultManager requestPlayerItemForVideo:asset
                                                 options:options
                                           resultHandler:^(AVPlayerItem *item, ...) {
    // 이 item을 AVPlayer에 그대로 물린다 — export 없음
}];
```

`requestPlayerItem` / `requestAVAsset`은 **iOS 8부터 있는 안정된 공개 API**이고,
슬로모션·편집본·HDR을 AVFoundation이 알아서 처리한다.

**단, URL을 뽑아내는 우회는 iOS 18에서 막혔다.** 이게 이 패키지가 필요한
결정적 이유다.

### 3.3 iOS 18의 변화 — 값싼 우회의 종말 [중요]

iOS 17까지는 이런 편법이 통했다:

```objc
AVURLAsset *urlAsset = (AVURLAsset *)avAsset;
NSURL *videoURL = urlAsset.URL;   // 원본 경로
// → 이 경로를 Flutter로 넘겨 VideoPlayerController.file(...)로 재생
```

**iOS 18부터 `NSCocoaErrorDomain 257 (권한 없음)`으로 실패한다.**
애플 DTS(Quinn "The Eskimo!")의 답변:

> "iOS has a sandbox that prevents your app from accessing arbitrary files on the
> file system... If you want to access files outside of your app's sandbox, you must
> go through the relevant system API to gain access to those files.
> **Those APIs extend your sandbox to grant you the access you need.**"

즉 **샌드박스 확장은 PhotoKit이 건네준 `AVAsset`/`AVPlayerItem` 객체에 붙는 것**이지,
거기서 추출한 경로 문자열에 붙는 것이 아니다.

| 방법 | iOS 17 | iOS 18+ |
|---|---|---|
| `AVAsset` 객체를 그대로 `AVPlayer`에 물림 | ✅ | ✅ |
| `AVAsset.url`을 뽑아 **다른 플레이어**에 넘김 | ✅ | ❌ **257** |
| `PHAssetResourceManager`로 샌드박스에 복사 | ✅ | ✅ (= 현재 방식) |

**결론: `AVPlayer`를 만드는 주체가 `AVPlayerItem`을 직접 쥐고 있어야 한다.**
Flutter 쪽으로 경로만 넘기는 얇은 헬퍼로는 원리적으로 불가능하고,
**플레이어를 가진 패키지**가 PhotoKit을 함께 쥐어야 한다.

또 하나의 iOS 18 잔가시: `requestAVAsset`이 주는 URL에 `#YnBsaXN0MDD...` 형태의
fragment가 붙는다. `URL(filePath: asset.url.relativePath)`로 제거한다.
(이 패키지는 URL을 안 쓰므로 무관하지만, 기존 코드 마이그레이션 시 만날 수 있다.)

**근거:** [Apple Forums 758691](https://developer.apple.com/forums/thread/758691) ·
[760499](https://developer.apple.com/forums/thread/760499) ·
[requestAVAsset 문서](https://developer.apple.com/documentation/photokit/phimagemanager/1616935-requestavasset)

---

## 4. 왜 기존 플레이어 패키지가 이걸 못 하는가 [maintainer 설득의 핵심]

기술적 한계가 아니다. **패키지 경계 문제**다.

조사 결과:

| 패키지 | `Photos.framework` 링크 | 갤러리 직결 |
|---|---|---|
| `video_player` (Flutter 팀) | ❌ (`PHAsset` 참조 0건) | ❌ |
| `video_player_avfoundation` | ❌ | ❌ |
| `native_video_player` | ❌ (podspec에 `s.dependency 'Flutter'`뿐) | ❌ |
| `better_native_video_player` | ❌ | ❌ |

**왜 링크하지 않는가:** iOS에서 `Photos.framework`를 링크하면 그 플러그인을 쓰는
**모든 앱**이 `NSPhotoLibraryUsageDescription`을 요구받고, 심사에서 "왜 사진
라이브러리 접근이 필요한가"에 답해야 한다. 영상만 재생하는 앱에는 부당한 비용이다.
**범용 플레이어가 이 결정을 내릴 수 없다.**

### 이 판단의 선례는 `photo_manager` 자신에게 있다

`photo_manager` 3.12.0 CHANGELOG:

> "The Darwin (iOS/macOS) implementation **no longer links `CoreLocation`**, so apps
> that do not save assets with location no longer need an
> `NSLocationWhenInUseUsageDescription` purpose string (#1428). Saving with
> `latitude`/`longitude` on iOS/macOS now throws;
> **install the `photo_manager_location` plugin** to keep that capability."

사진 라이브러리를 다루는 코어 패키지조차 **불필요한 프레임워크 링크를 걷어내고,
필요한 사람만 쓰는 컴패니언 패키지로 분리**하는 방향을 이미 선택했다.

그렇다면 반대 방향도 같은 논리로 성립한다 —
**`Photos.framework`를 이미 링크한 쪽(=photo_manager 생태계)이,
플레이어를 필요로 하는 사람에게만 컴패니언으로 제공하는 것.**

### 컴패니언 저장소에 자리가 비어 있다

[`fluttercandies/flutter_photo_manager_plugins`](https://github.com/fluttercandies/flutter_photo_manager_plugins)
(Apache-2.0, 열린 이슈 0, 2026-08 활동):

```
packages/
├── photo_manager_image_provider   AssetEntity → ImageProvider   (이미지)
├── photo_manager_location         CoreLocation 분리             (위치)
└── ???                            AssetEntity → 재생            (영상)  ← 비어 있음
```

**비대칭이 그대로 드러난다.** 이미지에는 `photo_manager_image_provider`가 있어
`AssetEntity`를 위젯에 바로 꽂을 수 있는데, **영상에는 대응물이 없다.**
그래서 모든 사용자가 `entity.file`로 복사한 뒤 `video_player`에 넘기는,
갤러리 UX에 맞지 않는 우회를 각자 재발명하고 있다.

이 패키지는 **그 대칭을 완성하는 세 번째 조각**이다.

---

## 5. 설계 스케치

```
                    ┌──────────────────────────────┐
   Dart 공통 API →  │  GalleryVideoController       │
                    │   .fromAsset(AssetEntity)     │
                    │   play / pause / seek / …     │
                    │   position · duration · state │
                    └───────────────┬───────────────┘
                                    │
              ┌─────────────────────┴─────────────────────┐
              ▼                                            ▼
   Android (프레임워크 추가 0)                    iOS (Photos.framework)
   MediaStore content:// URI                     PHImageManager
        → ExoPlayer                                .requestPlayerItem
                                                     → AVPlayer
   복사 0바이트                                   복사 0바이트
```

| 항목 | Android | iOS |
|---|---|---|
| 입력 | `AssetEntity.id` (MediaStore id) | `AssetEntity.id` (PHAsset localIdentifier) |
| 해석 | `content://media/external/video/media/{id}` | `PHAsset.fetchAssets(withLocalIdentifiers:)` |
| 재생 | ExoPlayer | `AVPlayer(playerItem:)` |
| 렌더링 | 1차 PlatformView (검증된 경로) → 텍스처는 실측 후 판단 | 동일 |

**Dart 쪽은 완전히 동일한 컨트롤러 하나.** 플랫폼 분기는 플러그인 안에 갇힌다.

### 갤러리 UX가 실제로 요구하는 것 (범위 결정 근거)

| 요구 | 이유 |
|---|---|
| **포스터 프레임 → 크로스페이드** | 준비 중 검은 화면을 보이지 않는다. 썸네일은 이미 캐시에 있다 |
| **인접 ±1 프리로드** | 스와이프 즉시 재생 |
| **컨트롤러 상한** | 기기 코덱 인스턴스 한도(보통 8~16) 보호 |
| **첫 프레임 신호** | 전환 시점 판단. `video_player`에는 없는 값 |

마지막 항목은 기존 플레이어가 주지 않아 모두가 `position > 0` 같은 어림짐작을
쓰고 있다. 갤러리 전용 패키지라면 정직하게 제공할 수 있다.

---

## 6. 범위

### 넣는다
- `AssetEntity`(또는 id) 입력으로 재생
- play / pause / seek / volume / loop
- position · duration · buffering · **firstFrameRendered**
- 인접 프리로드 헬퍼, 컨트롤러 풀 상한
- iCloud 미다운로드 진행률 (iOS)

### 넣지 않는다
- PiP, 자막, DRM, 오디오 세션 커스터마이즈, 캐스팅
- 네트워크 URL 재생 (그건 `video_player`의 몫)

경계는 명확하다 — **"사진 라이브러리에 있는 영상을 갤러리처럼 재생한다"** 하나.

---

## 7. 리스크 — 열거 가능하고 유한하다

| 케이스 | 처리 | 비고 |
|---|---|---|
| 슬로모션 | `requestPlayerItem`이 composition 반환 → 그대로 재생 | export 방식보다 오히려 쉽다 |
| 편집된 영상 | `.current` 버전이 편집본 반환 | 자동 |
| HDR / Dolby Vision | AVFoundation / ExoPlayer 처리 | 분기 없음 |
| 확장자·코덱 (MOV/MP4/HEVC…) | 플랫폼 플레이어 처리 | **분기 없음** |
| iCloud 미다운로드 | `isNetworkAccessAllowed` + 진행률 | 테스트 필요 |
| 삭제된 자산 | fetch 실패 → 명시적 에러 | 테스트 필요 |
| Android 권한 축소(선택 접근) | content URI 접근 불가 → 에러 | 테스트 필요 |

**확장자·코덱별 분기가 없다는 점이 중요하다.** "예외가 너무 많아 언제 안정될지
모른다"는 성격의 작업이 아니다. 실제 비용은 **플레이어 플러밍을 소유하는 것**이고,
그건 범위가 명확한 대신 지속적인 유지보수가 따른다.

---

## 8. maintainer에게 보낼 초안

> **제목:** Proposal: `photo_manager_video_player` companion plugin
>
> Hi — I'm the author of #1319, #1320 and #1372.
>
> **Problem.** Playing a gallery video today requires `entity.file`, which copies the
> whole original into the app sandbox (Android scoped cache) or runs an
> `AVAssetExportSession` (Darwin). For a gallery-style UI where users swipe quickly
> through videos, that copy is the dominant latency, and it brings cancellation,
> disk-cleanup and concurrency problems with it.
>
> **What changed.** Until iOS 17 you could take the URL out of
> `requestAVAsset` and hand it to any player. Since iOS 18 that fails with
> `NSCocoaErrorDomain 257` — Apple DTS confirmed the sandbox extension is attached to
> the `AVAsset` object PhotoKit hands you, not to the extracted path
> ([forums/758691](https://developer.apple.com/forums/thread/758691)).
> So the component that creates the `AVPlayer` must hold the `AVPlayerItem` itself.
>
> **Why no general player can fix this.** `video_player`,
> `video_player_avfoundation` and `native_video_player` all deliberately avoid linking
> `Photos.framework` — linking it would force every app using them to declare
> `NSPhotoLibraryUsageDescription`. That's the same reasoning behind 3.12.0's
> `CoreLocation` removal and the `photo_manager_location` split.
>
> **The gap.** `flutter_photo_manager_plugins` already has
> `photo_manager_image_provider` for images. There is no counterpart for video, so
> every user re-invents the copy-then-play workaround.
>
> I'd like to build `photo_manager_video_player` — Android via MediaStore
> `content://` + ExoPlayer, Darwin via `PHImageManager.requestPlayerItem` + `AVPlayer`,
> behind one Dart controller. Zero copies on both platforms.
>
> Would you be open to this living in `flutter_photo_manager_plugins`? I'm happy to
> develop it in my own repo first and propose it upstream once it's proven in
> production. Either way I'd value your input on the API shape before I start.

**저자 신뢰도 근거 (머지된 PR):**

| PR | 머지일 | 내용 |
|---|---|---|
| [#1319](https://github.com/fluttercandies/flutter_photo_manager/pull/1319) | 2025-11-20 | Android batch move assets |
| [#1320](https://github.com/fluttercandies/flutter_photo_manager/pull/1320) | 2025-11-20 | `AssetPathEntity.relativePathAsync` |
| [#1372](https://github.com/fluttercandies/flutter_photo_manager/pull/1372) | 2026-03-05 | `CustomFilter` CI 호환성 수정 |

---

## 9. 왜 `native_video_player` 포크가 아닌가

처음에는 검증된 플레이어를 포크해 PhotoKit 조각만 얹는 안을 검토했다.
저장소 상태를 확인한 결과 기여 경로로는 부적합했다:

| 신호 | 값 |
|---|---|
| 라이선스 | MIT (포크 자체는 자유) |
| 별 / 열린 이슈 | 46 / 31 |
| **마지막 외부 PR 머지** | **2024-12-16 (#29) — 21개월 전** |
| PR #27 "use exoplayer, hybrid composition" | **2024-12-01 열림, 아직 열려 있음** |
| 커밋 공백 | 2025-05 → 2026-06 (13개월) |

안드로이드 렌더링을 개선하는 PR이 21개월째 방치돼 있다. 업스트림 기여는 기대하기
어렵고, 포크는 유지보수를 우리가 떠안는 것과 같다. **그럴 바에는 경계가 명확한
갤러리 전용 패키지를 처음부터 짓는 편이 낫다.**

구현 참고 자료로서는 여전히 유용하다 (AVPlayer + AVPlayerLayer 구조, MIT).

---

## 10. 다음 단계

- [ ] maintainer에게 8절 초안으로 의사 타진 (Discussion 또는 Issue)
- [ ] Dart 공개 API 확정 (`GalleryVideoController` 시그니처)
- [ ] Android 구현 — MediaStore content URI + ExoPlayer
- [ ] iOS 구현 — `requestPlayerItem` + AVPlayer
- [ ] 렌더링 경로 결정 (PlatformView → 텍스처 실측 비교)
- [ ] 7절 리스크 케이스별 실기기 테스트
- [ ] Zelly 앱에 `path:` 의존으로 통합해 실사용 검증
- [ ] pub.dev 배포 / 업스트림 합류 제안

---

## 부록 — 확인한 근거 목록

| 사실 | 근거 |
|---|---|
| Android `entity.file`은 전체 복사 | `AndroidQDBUtils.kt:301-310` (photo_manager 3.8.3) |
| Android `getMediaUrl`은 URI만 반환 | `IDBUtils.kt:510` |
| iOS `file`/`getMediaUrl` 모두 export | `PMManager.m:761-776`, `:1532-1570` |
| `video_player`에 Android 전용 `contentUri` 생성자 존재 | `video_player.dart:473-480` |
| `video_player_avfoundation`에 PhotoKit 참조 0건 | pub-cache 전체 grep |
| `native_video_player` podspec에 프레임워크 링크 없음 | `ios/native_video_player.podspec` |
| iOS 18에서 URL 우회 차단 (오류 257) | [Apple Forums 758691](https://developer.apple.com/forums/thread/758691) |
| iOS 18 URL fragment 이슈 | [Apple Forums 760499](https://developer.apple.com/forums/thread/760499) |
| photo_manager가 CoreLocation을 분리한 선례 | photo_manager 3.12.0 CHANGELOG |
| 컴패니언 저장소 구조 | [flutter_photo_manager_plugins](https://github.com/fluttercandies/flutter_photo_manager_plugins) |
| `native_video_player` 유지보수 상태 | GitHub API 조회 (2026-09-02) |

> 조사 시점: 2026-09-02 · photo_manager 3.8.3(앱 사용) / 3.12.0(최신) 기준
