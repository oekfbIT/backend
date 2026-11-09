# Jersey kit generation

The generator is a standalone image transformation, with no team lookup, Firebase upload,
database write, confirmation, or assignment. A caller can use it from its own authenticated flow:

```swift
let generated: File = try await JerseyKitGenerationService(client: req.client)
    .generate(image: uploadedImage)
// generated.filename == "generated-kit.png"; generated.data contains the PNG bytes.
// Return those bytes, or handle confirmation/storage/assignment in the caller.
```

Set `OPENAI_API_KEY` (the existing shared OpenAI key). Optional configuration:

| Variable | Default |
| --- | --- |
| `JERSEY_KIT_IMAGE_MODEL` | `gpt-image-2.5-sunburst-2026-09-08` |
| `JERSEY_KIT_TIMEOUT_SECONDS` | `180` (bounded to 30–600) |

The service reuses Vapor's injected `Client` and calls the
[OpenAI image editing API](https://developers.openai.com/api/reference/resources/images/methods/edit)
with two image references. The first is the uploaded jersey; the second is the user's original
mockup bundled at `Sources/App/Resources/jersey-kit-layout.png`. An optional `layoutReference: File`
constructor parameter allows a trusted server-owned replacement without accepting remote URLs.

The pinned default model, fixed prompt, and reference standardize composition: jersey, matching shorts, white socks,
and white boots with black details. The image model interprets the jersey directly; there is no
separate analysis request or analysis response. Unclear markings are omitted, unclear designs
are simplified, and undetectable colors fall back to neutral gray. These are model instructions,
not guarantees of exact reproduction. There is no seed or guarantee of identical pixels between
calls, and garment count/design fidelity are not mechanically verified.

Input: PNG/JPEG, nonempty, maximum 10 MiB, detected using file signatures independently of the
supplied filename/MIME type, following existing upload validation. This does not fully decode
the input image; the provider may reject corrupt image content. Output: one 1024×1536 PNG.
Validation checks PNG structure, CRCs, complete scanline decompression, all PNG row filters,
visible pixels, and actual zero-alpha pixels at the canvas boundary. Opaque/empty images fail
explicitly. The output validator accepts non-interlaced 8-bit RGBA only; other encodings fail
rather than bypass transparency validation. This checks transparency, not semantic composition.

Provider errors are sanitized. Explicit 429/500/502/503/504 responses are retried once, after
1–5 seconds. Transport errors/timeouts are not automatically retried to avoid duplicate billed
generations. A retry following a provider error can still incur another generation charge.
No image payloads or API credentials are logged. Tests mock all provider calls:

```sh
swift test --filter JerseyKitGenerationTests
```

The PNG validator uses system zlib (`zlib1g-dev` on Linux builds); no new remote Swift package
or image-processing executable is required.

## Admin team → Kits

The admin team detail page shows Home and Away cards in the **Kits** tab. Select a PNG/JPEG,
then either save the original or request the unified style. Generation opens a local preview;
**Verwerfen** leaves the stored kit untouched. **Freigeben & speichern** uploads and assigns
the generated PNG. Only successful saves update the page's saved-team snapshot. Other unsaved
team edits must be saved before starting kit edits.

Both routes require admin authentication and `teams.update`:

- `POST /admin/jersey-kits/generate`: multipart `image`; returns raw `image/png`, `Cache-Control: no-store`.
  Does not upload to Firebase or modify a team.
- `PUT /admin/teams/:id/jerseys/:side`: `side` is `home` or `away`; multipart `image` and
  `expectedImageUrl` (empty string if none). Returns `{ "side": "home", "imageUrl": "..." }`.
  Saves to a unique Firebase object and atomically replaces only that side's URL. A stale
  `expectedImageUrl` returns 409. Storage failure leaves the current kit unchanged. A conflict
  or database failure after uploading can leave an unassigned Firebase object; the old image
  is retained rather than deleted or overwritten in place. The selected team's saved URL is
  replaced, while the other side and unrelated team fields are preserved.

The save limit is 20 MiB to accommodate generated images; source photos remain limited to 10 MiB.
The generation and save routes call separate functions; the generation service remains reusable.
To run the isolated Mongo save test, set `JERSEY_KIT_TEST_MONGO_PORT` to a local test server port
when running `swift test --filter AdminJerseyKitTests`. Firebase and image generation are mocked.
