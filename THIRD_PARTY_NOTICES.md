# Third-Party Notices

CatPointer for macOS includes cursor artwork derived from the **猫标**
cursor theme.

- Original artwork and animation: **HappyCadogt**
  ([Bilibili @406949928](https://space.bilibili.com/406949928))
- macOS source assets obtained from:
  [Tseshongfeeshur/cat-cursors](https://github.com/Tseshongfeeshur/cat-cursors)
- Exact source revision:
  [`d3d6ca1a31510f2e5dcf2b69155fb1a5294978e2`](https://github.com/Tseshongfeeshur/cat-cursors/commit/d3d6ca1a31510f2e5dcf2b69155fb1a5294978e2)
- Upstream port and repository copyright: Copyright (c) 2025 Ryan
- Upstream repository license: MIT License. CatPointer relies on the license
  designation supplied by that upstream repository and does not claim a
  separate direct license grant from the original artist. The complete
  upstream license text is included at
  `Resources/Licenses/cat-cursors-MIT.txt` in the source tree and at
  `Contents/Resources/Licenses/cat-cursors-MIT.txt` in the packaged app.

The included `default`, `text`, `pointer`, `progress`, `wait`, `size_hor`, and
`size_ver` frame sequences come from the corresponding animated cursor
sources in that revision. CatPointer preserves the original artwork. At
runtime it uniformly samples each source sequence to 24 frames,
the maximum supported by the macOS private cursor-registration interface,
using only unmodified source images. All four user-facing speeds reuse the
same motion-faithful selection of original frames. “Slow” retains the source
sequence's complete cycle duration; Medium, Fast, and Extreme play those same
frames at 12, 20, and 30 FPS.

The original artwork also appears in these derived project assets:

- `Resources/AppIcon.png`
- `Resources/CatPointer.icns`
- `Validation/catpointer-original-preview.png`

The icon subject is composited directly from `Resources/Cursors/default/26.png`.
The separate peach background at
`Resources/IconSource/AppIconBackground-chroma.png` was generated for
CatPointer with OpenAI image tooling and retains its C2PA provenance metadata;
it is not part of the upstream artwork.

CatPointer's own source code and documentation are licensed separately under
the project-level `LICENSE`. That project license does not replace the
attribution and license notice for the third-party artwork above.

The upstream software and assets are provided under the following notice:

> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.
