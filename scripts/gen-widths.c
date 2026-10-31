/*
 * gen-widths.c — write `Sources/krd/WidthTable.swift` from libghostty's own Unicode tables.
 *
 * WHY a generator instead of a hand-written table: krd's old table was EastAsianWidth plus
 * "emoji are wide", and it was wrong in both directions -- `☰` (U+2630) is two cells on Ghostty and
 * Rex and the table said one, a flag was one cell and the terminals draw two. The only table that
 * cannot drift from what the terminal does is the terminal's own, so this reads it out of
 * libghostty-vt and bakes the answer in as ranges. Build and run it with `scripts/gen-widths.sh`.
 *
 * The four sets, and why each one is enough to reproduce `ghostty_unicode_grapheme_width` for a
 * cluster that this side has already segmented (Swift's `Character` is a UAX #29 cluster, so the
 * segmentation question is answered before the width question is asked):
 *
 *   1. `wide`   -- ghostty_unicode_codepoint_width == 2. The cluster starts at its first codepoint's
 *                  width, and a later codepoint can only widen it.
 *   2. `zero`   -- ghostty_unicode_codepoint_width == 0 (combining marks, ZWJ, VS1-15, tags).
 *   3. `widens` -- appending the codepoint to a base makes the cluster two cells. That is
 *                  `width_zero_in_grapheme == false` restricted to codepoints that actually join a
 *                  cluster, which is the only case krd can ask about -- derived by measurement
 *                  (`grapheme_width(base + cp)`) rather than by reading a private field, over the
 *                  handful of bases listed below because a codepoint only joins the clusters its
 *                  grapheme-break class allows.
 *   4. `vsBase` -- the codepoint is a valid emoji variation sequence base:
 *                  `[cp, VS16] == 2` and `[cp, VS15] == 1`. Both selectors have to behave, otherwise
 *                  an already-wide codepoint that is NOT a base (`[cp, VS16]` is 2 because cp alone
 *                  is 2) would be mistaken for one, and `⌚ + VS15` would stay two cells when the
 *                  terminal draws it as one.
 *
 * C0/C1 controls are deliberately left out of `zero`: krd's `DisplayWidth` answers 1 for them, and
 * every caller replaces them with a space before measuring. Baking 0 in would silently change
 * `truncate` for text krd does not control.
 */
#include <ghostty/vt/unicode.h>
#include <stdint.h>
#include <stdio.h>

#define MAX_CP 0x110000

static uint8_t width1(uint32_t cp) { return ghostty_unicode_codepoint_width(cp); }

static uint8_t width2(uint32_t a, uint32_t b) {
    uint32_t cps[2] = {a, b};
    uint8_t w = 0;
    ghostty_unicode_grapheme_width(cps, 2, &w);
    return w;
}

/* The bases for the `widens` probe. A codepoint only joins a cluster that its grapheme-break class
 * agrees with, so one base is not enough: `A` catches the Indic spacing marks, `あ` the kana sound
 * marks, `☝`/`❤` the narrow emoji bases (a skin tone joins those but does *not* widen one), `1` the
 * keycap marks and `1100`/`0915` the Hangul and Devanagari cases. A codepoint counted as widening
 * when *any* of them grows to two cells is exactly the set krd needs: `DisplayWidth.of(Character)`
 * is only ever asked about codepoints Swift already knows joined.
 *
 * Every base has to be **one cell wide**, and that is a trap rather than a detail: a two-cell base
 * makes the probe answer 2 for every codepoint in Unicode, because a codepoint that does not join
 * the cluster is measured as its own first cluster -- the base. The generated set is checked for
 * being small and sane by `WidthTableTests.testTheTablesAreSortedAndMerged`; the first run of this
 * script that got it wrong produced a table saying the whole of Unicode widens. */
static const uint32_t PROBE_BASES[] = {0x41, 0x31, 0x261D, 0x2764, 0x0915};
#define PROBE_BASE_COUNT (sizeof(PROBE_BASES) / sizeof(PROBE_BASES[0]))

static int is_control(uint32_t cp) {
    return cp < 0x20 || (cp >= 0x7F && cp <= 0x9F);
}

typedef struct { uint32_t start, end; } Range;

static Range ranges[4][4096];
static int counts[4];

static void add(int set, uint32_t cp) {
    if (counts[set] > 0 && ranges[set][counts[set] - 1].end + 1 == cp) {
        ranges[set][counts[set] - 1].end = cp;
        return;
    }
    if (counts[set] == 4096) {
        fprintf(stderr, "gen-widths: set %d overflowed at U+%04X\n", set, cp);
        return;
    }
    ranges[set][counts[set]].start = cp;
    ranges[set][counts[set]].end = cp;
    counts[set]++;
}

static void emit(const char *name, const char *doc, int set) {
    printf("\n    /// %s\n", doc);
    printf("    static let %s: [UInt32] = [\n", name);
    for (int i = 0; i < counts[set]; i++) {
        if (i % 4 == 0) printf("        ");
        printf("0x%04X, 0x%04X, ", ranges[set][i].start, ranges[set][i].end);
        if (i % 4 == 3 || i == counts[set] - 1) printf("\n");
    }
    printf("    ]\n");
    fprintf(stderr, "gen-widths: %-7s %5d ranges\n", name, counts[set]);
}

int main(void) {
    for (uint32_t cp = 0; cp < MAX_CP; cp++) {
        if (cp >= 0xD800 && cp <= 0xDFFF) continue;   /* surrogates are not scalars */
        uint8_t w = width1(cp);
        if (w == 2) add(0, cp);
        else if (w == 0 && !is_control(cp)) add(1, cp);
        for (unsigned i = 0; i < PROBE_BASE_COUNT; i++) {
            if (width2(PROBE_BASES[i], cp) == 2) { add(2, cp); break; }
        }
        if (width2(cp, 0xFE0F) == 2 && width2(cp, 0xFE0E) == 1) add(3, cp);
    }

    printf("// Generated by scripts/gen-widths.sh -- do not edit.\n");
    printf("//\n");
    printf("// Source: libghostty-vt v1.4.0 (tag 83fb956), Unicode 17.0, emoji 18.0.\n");
    printf("// Regenerate: scripts/gen-widths.sh [path-to-libghostty-checkout]\n");
    printf("//\n");
    printf("// Why this is generated and not written by hand: krd's old table was EastAsianWidth plus\n");
    printf("// \"emoji are wide\", and it disagreed with the terminals krd is tested against in both\n");
    printf("// directions -- `☰` (U+2630) is two cells in Ghostty and Rex and the table said one, and a\n");
    printf("// flag was one cell where they draw two. These are libghostty's own width tables, so the\n");
    printf("// arithmetic below cannot drift from what a 2027-aware terminal draws.\n");
    printf("enum WidthTable {\n");
    emit("wide", "Codepoints a terminal draws in two cells (ghostty_unicode_codepoint_width == 2).", 0);
    emit("zero", "Codepoints that occupy no cell of their own: combining marks, joiners, VS1-VS15, tags.", 1);
    emit("widens", "Codepoints that make a cluster two cells when they join one (width_zero_in_grapheme == false).", 2);
    emit("vsBase", "Valid emoji variation sequence bases: VS16 makes them two cells, VS15 makes them one.", 3);
    printf("\n}\n");
    return 0;
}
