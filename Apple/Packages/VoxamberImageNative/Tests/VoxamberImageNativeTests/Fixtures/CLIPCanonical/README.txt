Pure tokenizer test corpus only. These are not neural weights or a usable full tokenizer vocabulary.
Golden IDs come from OpenAI/CLIP simple_tokenizer.py commit 3bee28119e6b28e75b82b811b87b56935314e6a5,
using the already SHA-verified official Apple SDXL vocab/merges. Only the merge closure encountered
by the fixed vectors and original vocabulary IDs is retained. A separate full-assets native CPU
check verifies all 22 input/pad combinations with all 49408 entries/48894 rules.
Original OpenAI MIT and Apple MIT notices are retained at package root. MODEL-LICENSE-SDXL.md
retains the compiled model's independent license. No inference or image output is a test fixture.
