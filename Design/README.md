# Website demo assets

The website and repository use `website/assets/hero-demo.png`: a screenshot rendered by OneAct's actual AppKit interface, with a fictional scene placed inside the preview canvas. No real-person footage or private screen content is used.

`Design/demo-scene.png` is an AI-generated presentation and illustrated presenter, created with the built-in imagegen tool on 2026-10-15. It is a presentation fixture, not a demonstration of an avatar-generation feature in OneAct. The website and README label it as an illustrative demo scene.

## Reproduce the screenshot

On macOS 15+ with the Swift 6 toolchain:

```bash
./scripts/render-demo.sh
```

The script builds an isolated demo bundle under `build/demo/`, then renders the actual controls and the supplied image. Its bundle identifier is separate from the normal app. Layout-report mode skips live capture, device enumeration, global shortcuts, and update checks. The existing `website/assets/hero.png` is retained as the earlier empty-canvas reference.

## Generation prompt

Built-in imagegen, new image, opaque background:

> Use case: productivity-visual. Asset type: a 16:9 demo canvas to be displayed INSIDE a real macOS screen-recording app screenshot. Create only the demo canvas, no app chrome, no laptop, no browser, no outer frame. A polished keynote-style presentation on warm ivory, charcoal typography, coral-red and soft sage accents matching a dark recording app with a coral Record button. Main composition: large editorial title at upper left exactly "From idea to one take."; small eyebrow exactly "A SIMPLE RECORDING WORKFLOW". Three spacious numbered cards in the left and center two thirds, each with a simple beautiful geometric icon and exact short labels: "01 Prepare", "02 Compose", "03 Record". Small subtitle below the title exactly "Your screen. Your story.". On the lower right, an obviously fictional stylized 3D clay illustrated presenter, waist-up, with a warm friendly expression, simplified face, dark curly hair, a coral overshirt over an ivory shirt, one relaxed open hand gesturing toward the cards. The presenter should look like a high-quality animated illustration, never a photograph or a realistic human likeness. The character is an overlay with a clean silhouette and occupies the rightmost quarter, anchored to the bottom edge, with no circular frame. Keep all card text well clear of the presenter. Balanced, minimal, premium product demo art; big legible text, generous whitespace, subtle warm shadows, coherent 3D geometric visual language. No real people, no personal data, no logos, no watermarks, no extra text. High-resolution landscape 16:9.
