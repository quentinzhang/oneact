# Website demo assets

## Shared brand icon

`Design/oneact-icon-b-spotlight.svg` is the canonical OneAct icon: coral `#e5484d`, warm ivory `#ffe9c4`, and dark navy `#171a26`. The application bundle, window header, Dock, Finder, website logo, and web icons share this artwork. The curtain SVG is an unused design alternative.

Run `swift scripts/render-icons.swift` on macOS to regenerate `AppIcon.icns`, `website/assets/logo.svg`, and `website/assets/icon-256.png`. The script uses AppKit and `iconutil`, with no third-party dependencies. Then run `./scripts/package-app.sh` and `./scripts/render-demo.sh` to update the app and its three website screenshots. OneAct loads the bundled icon at launch so its Dock and header use the current artwork even when macOS has cached an older version.

The website provides three switchable previews, rendered by OneAct's actual AppKit interface with fictional scenes inside the preview canvas. No real-person footage or private screen content is used.

| Preview | Screenshot | Canvas fixture |
| --- | --- | --- |
| Camera | `website/assets/demo-camera.png` | `Design/demo-camera-scene.png` |
| Screen + Camera | `website/assets/hero-demo.png` | `Design/demo-scene.png` |
| With Teleprompter | `website/assets/demo-teleprompter.png` | `Design/demo-scene.png` plus the real teleprompter panel |

Both canvas fixtures were created with the built-in imagegen tool on 2026-10-15. The Camera scene uses the presentation scene as a character reference. They are presentation fixtures, not a demonstration of an avatar-generation feature in OneAct. The website and README label them as illustrative scenes.

## Reproduce all three screenshots

On macOS 15+ with the Swift 6 toolchain:

```bash
./scripts/render-demo.sh
```

The script builds an isolated demo bundle under `build/demo/`, then renders the actual controls and the supplied images. Its bundle identifier is separate from the normal app. Layout-report mode skips live capture, device enumeration, global shortcuts, and update checks. It also disables teleprompter script loading and saving, so the fixtures cannot expose or overwrite a user's saved script. The existing `website/assets/hero.png` is retained as the earlier empty-canvas reference.

The teleprompter is a separate child window. For the website fixture only, its actual AppKit content is rendered at its window position on top of the main-window image. The recording compositor is unchanged and does not include that overlay. The sample script is fixed English text; the third preview shows Screen + Camera with the teleprompter enabled, and the same feature is available in Camera mode.

The website tabs support clicking, Left/Right arrows, Home, and End. Without JavaScript all three previews remain visible.

## Camera generation prompt

Built-in imagegen, reference image `Design/demo-scene.png`, opaque background:

> Use case: productivity-visual. Create a companion 16:9 camera-only demo canvas for a macOS recorder, using the attached illustration as the character and style reference. Preserve exactly the same obviously fictional clay illustrated presenter: dark curly sculpted hair, warm tan clay skin, friendly simplified face, coral overshirt with ivory buttons over an ivory T-shirt. Reframe him as a centered chest-up talking-to-camera shot, looking directly at the viewer with a relaxed smile, shoulders and upper torso visible, head with generous comfortable top margin. The presenter occupies the middle half of the canvas; no hands need be visible. Replace the presentation slide with a warm minimalist illustrated home studio: luminous warm ivory backdrop, a softly blurred small sage plant at the far left, a subtle pale coral abstract wall shape at far right. Clean, spacious, premium, soft diffused studio light, coherent tactile 3D clay illustration. No realistic human or photograph, no text, no logos, no cards or presentation content, no borders, no app chrome, no laptop, no watermark. Only the 16:9 scene that will be inserted into the real app preview. Opaque background.

## Screen + Camera generation prompt

Built-in imagegen, new image, opaque background:

> Use case: productivity-visual. Asset type: a 16:9 demo canvas to be displayed INSIDE a real macOS screen-recording app screenshot. Create only the demo canvas, no app chrome, no laptop, no browser, no outer frame. A polished keynote-style presentation on warm ivory, charcoal typography, coral-red and soft sage accents matching a dark recording app with a coral Record button. Main composition: large editorial title at upper left exactly "From idea to one take."; small eyebrow exactly "A SIMPLE RECORDING WORKFLOW". Three spacious numbered cards in the left and center two thirds, each with a simple beautiful geometric icon and exact short labels: "01 Prepare", "02 Compose", "03 Record". Small subtitle below the title exactly "Your screen. Your story.". On the lower right, an obviously fictional stylized 3D clay illustrated presenter, waist-up, with a warm friendly expression, simplified face, dark curly hair, a coral overshirt over an ivory shirt, one relaxed open hand gesturing toward the cards. The presenter should look like a high-quality animated illustration, never a photograph or a realistic human likeness. The character is an overlay with a clean silhouette and occupies the rightmost quarter, anchored to the bottom edge, with no circular frame. Keep all card text well clear of the presenter. Balanced, minimal, premium product demo art; big legible text, generous whitespace, subtle warm shadows, coherent 3D geometric visual language. No real people, no personal data, no logos, no watermarks, no extra text. High-resolution landscape 16:9.
