---
name: septena-photo-studio
description: Create and refine Septena Photo Studio lifestyle images and App Store panels, preserving the persimmon brand and adapting the concept across devices.
---

# Septena Photo Studio

Use this repo-local skill when creating Septena marketing images that show the task app on a device. Keep a lifestyle photo and an App Store panel as separate compositions; combine them only when asked.

## Sources and brand

- Read `docs/APPSTORE-SEPTASK.md` for the current task-app story and panel copy, `appstore/panels.septask.mjs` for panel direction, and `registry/tokens.json` for the current accent. The current Persimmon light accent is `#E05212`.
- Use a current Septena task-app screen as the display reference. Do not reuse the older all-in-one life-tracking screen. Check the active checkout for the scene or capture path before assuming where the current screen lives.
- Use synthetic example content only. Do not include real names, personal tasks, or private user data.
- Generated device screens are visual concepts: image generation can redraw small UI text. For release-ready screenshots, use the native app capture and the App Store rendering workflow.

## User's established visual direction

- Keep the device display in light appearance unless the user specifies another appearance. Show `9:41` when a status bar is requested.
- For Photo Studio lifestyle images, use a photorealistic, high-contrast black-and-white editorial scene with an anonymous person seen from behind. Keep the phone visible, slightly turned in perspective, and naturally held. Do not imply a specific person's identity.
- The user prefers a clean, uninterrupted top edge on the phone display: omit the notch, Dynamic Island, and camera cutout unless they ask otherwise.
- Keep the app's persimmon accents. Avoid blue accents unless the user explicitly requests them.
- The user prefers the hand a little smaller and more delicate than in the initial concept, while retaining a natural grip and realistic anatomy.

## Multi-device composition

When the user asks for the Mac, iPhone, and Watch composition based on the supplied dark App Store panel:

- Keep the large white headline above the devices, the dark charcoal topographic background, and the overlapping hierarchy: Mac wide in back, iPhone in the lower-right foreground, Watch in the lower-left foreground. Include only the requested devices; do not add iPad by default.
- Render the device bodies and setting as a black-and-white product photograph. Let the screens provide the color, with a soft persimmon glow reflected on nearby edges and desk surfaces.
- Use a current app screen on each device. The iPhone can carry the Today/Discuss hook screen; adapt the Mac and Watch interfaces to their own proportions. Do not put an iPhone-sized layout on the Mac or Watch.
- Keep device screens readable and free of notches on the iPhone. Avoid unrequested props and extra copy. The current explored copy is `One list, every device.` with `iPhone, Mac and Apple Watch.` beneath it; use the user's requested copy if it differs.
- Generated Mac and Watch screens are mockups unless current native captures are supplied. Do not describe them as actual screenshots.

## Intelligence visual treatments

Offer or use one treatment at a time, based on the user's direction:

1. **Screen light on the hand:** a soft Persimmon glow from the display across the fingertips and a small part of the cuff, with a faint halo at the glass edge. This is the cleanest, most photographic treatment. Keep the glow diffuse; omit floating graphics.
2. **Ideas taking shape:** a few faint, translucent line fragments and checkbox outlines near the phone, loosely scattered farther away and gently aligned into task-like rows near the screen. Keep them soft and sparse. Slightly larger ambient checkboxes are acceptable when requested.

Avoid sharp sparks, fire-like ribbons, sound-wave arcs, neon, circuitry, and dense floating UI. The user found ribbon-like light too much like fire or sound. Do not mix the two treatments unless requested.

## Current hook-panel example

When the user asks to recreate this hook screen, use the current brief as the content reference:

- App Store panel title: `Tasks that think with you`, large and standalone, with no subtitle.
- Today screen with an Inbox count of 2 and two synthetic tasks.
- Expanded Discuss card for `Send the launch update`, with `What should the update focus on?` and three answer chips: `What's new`, `Launch timing`, and `Next steps`.
- Below it, `Draft the launch brief` with an agent mark and `Your turn` visible.
- Finish with two or three ordinary unchecked Admin tasks.
- Do not show a keyboard, open menus, or an app-icon badge count.

Use the actual requested device and screen dimensions when supplied. For iPad, Mac, or another device, adapt the framing and use that device's real current screen as the interface reference; do not simply enlarge the iPhone mockup.

## Image workflow

- Use the built-in ImageGen tool by default. Treat current app screenshots as interface references and generated photos as edit targets. For edits, specify which image is the target, which is the screen reference, what must change, and what must stay fixed.
- Keep previews in the generated-images area unless the user asks for a project asset or gives a destination. Do not overwrite an existing image; use a new version. Report the full path and actual dimensions when available.
- Treat generated panel images as concepts unless they were produced from the native screenshot pipeline at the requested App Store dimensions.

## Existing visual references

These local previews show the two explored directions. Reuse them as optional visual references when they are available:

- Soft screen glow, smaller hand: `/Users/mz/.codex/generated_images/01a2093b-2163-7f20-9f77-c2a0b23c9640/exec-dadca38f-d4a9-4af4-adba-980a2d99032c.png`
- Ideas taking shape, larger ambient checkboxes: `/Users/mz/.codex/generated_images/01a2093b-2163-7f20-9f77-c2a0b23c9640/exec-e9cabfca-e3b5-41b8-88a9-41e5a0779a0f.png`
- Hook-panel composition concept: `/Users/mz/.codex/generated_images/01a2093b-2163-7f20-9f77-c2a0b23c9640/exec-c46f3ed3-34a9-471b-859d-ad897f90c908.png`
- Mac, iPhone, and Watch product-photo panel: `/Users/mz/.codex/generated_images/01a2093b-2163-7f20-9f77-c2a0b23c9640/exec-9f5f0f22-d512-402e-b119-a8d82a1a54cc.png`
