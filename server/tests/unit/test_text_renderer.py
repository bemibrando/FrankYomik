"""Regression tests for text rendering: SFX detection, hyphenation, word wrap."""

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from kindle.text_renderer import (
    _is_sound_effect,
    _word_wrap,
    _break_word_to_fit,
    _choose_layout,
    _cap_expanded_furigana_font_size,
    _cap_furigana_to_source_scale,
    compute_furigana_page_font_limits,
    estimate_source_vertical_font_size,
    _furigana_font_size,
    _fit_vertical_font_size,
    _fit_furigana_stack,
    _expand_bright_region_bbox,
    _mask_safe_bbox,
    _vertical_furigana_char_height,
    _vertical_main_char_height,
)
from kindle.config import FONT_EN


def _make_draw_and_font(size=16):
    img = Image.new("RGB", (1, 1))
    draw = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype(FONT_EN, size)
    except Exception:
        font = ImageFont.load_default()
    return draw, font


class TestSFXDetection:
    """Ensure SFX detection is selective — only match real sound effects."""

    def test_repeated_chars_are_sfx(self):
        assert _is_sound_effect("Grrr")
        assert _is_sound_effect("Aaaa")
        assert _is_sound_effect("AAAA!!")

    def test_specific_sfx_words(self):
        assert _is_sound_effect("Bam!")
        assert _is_sound_effect("Crash!")
        assert _is_sound_effect("Boom")
        assert _is_sound_effect("Wham!")

    def test_pure_punctuation_is_sfx(self):
        assert _is_sound_effect("!!")
        assert _is_sound_effect("...")
        assert _is_sound_effect("...!")

    def test_dialogue_is_not_sfx(self):
        """Common short dialogue words must NOT be classified as SFX."""
        assert not _is_sound_effect("Why?")
        assert not _is_sound_effect("Stop!")
        assert not _is_sound_effect("But...")
        assert not _is_sound_effect("No!")
        assert not _is_sound_effect("What?")
        assert not _is_sound_effect("Hey!")

    def test_multi_word_is_not_sfx(self):
        assert not _is_sound_effect("What is this?")
        assert not _is_sound_effect("That is")
        assert not _is_sound_effect("Here we go")

    def test_layout_choice(self):
        assert _choose_layout("Grrr") == "vertical_sfx"
        assert _choose_layout("!!") == "vertical_sfx"
        assert _choose_layout("Why?") == "horizontal"
        assert _choose_layout("Hello world") == "horizontal"


class TestFuriganaSizing:
    """Furigana should stay readable while layout reserves matching space."""

    def test_furigana_size_is_half_of_main_text(self):
        assert _furigana_font_size(24) == 12
        assert _furigana_font_size(30) == 15

    def test_furigana_size_keeps_minimum(self):
        assert _furigana_font_size(12) == 10

    def test_fit_uses_rendered_width_without_extra_furigana_reserve(self):
        chars = [{"char": "今", "furigana": "きょう"} for _ in range(8)]

        # With a 90px-wide bubble, 29px main text renders as two columns:
        #   2 * (29 main + 14 furigana + 2 gap) == 90px.
        # The fitter should allow that exact rendered width instead of
        # subtracting another furigana column from the available width.
        assert _fit_vertical_font_size(chars, bw=90, bh=200) == 29

    def test_vertical_cells_include_background_padding(self):
        # The old 1.05x cell was sometimes a pixel shorter than the actual
        # white background around CJK glyphs, so the next character could erase
        # the bottom of the previous one in tight stylized bubbles.
        assert _vertical_main_char_height(29) > int(29 * 1.05)
        assert _vertical_furigana_char_height(14) > 14 + 1

    def test_compressed_furigana_stack_uses_measured_spacing(self):
        main_cell = _vertical_main_char_height(29)
        size, cell = _fit_furigana_stack(target_size=14,
                                         total_height=main_cell,
                                         count=2)
        assert size <= 14
        assert cell * 2 <= main_cell

    def test_expanded_furigana_caps_near_original_text_scale(self):
        # Bright whitespace can improve cramped no-mask captions, but should not
        # turn normal narration into oversized headline text.
        assert _cap_expanded_furigana_font_size(40, 20) == 23
        assert _cap_expanded_furigana_font_size(60, 30) == 34

    def test_expanded_furigana_cap_does_not_force_growth(self):
        assert _cap_expanded_furigana_font_size(18, 20) == 18

    def test_source_scale_cap_is_per_bubble(self):
        assert _cap_furigana_to_source_scale(60, 20) == 23
        assert _cap_furigana_to_source_scale(18, 20) == 18

    def test_page_font_limits_cap_normal_dialogue_but_preserve_outliers(self):
        cap, outlier = compute_furigana_page_font_limits([20, 21, 22, 30, 45])

        assert cap == 26
        assert outlier == 34

    def test_estimates_small_source_text_in_large_bubble(self):
        img = Image.new("RGB", (160, 220), "white")
        draw = ImageDraw.Draw(img)
        for y in range(55, 145, 22):
            draw.rectangle((72, y, 88, y + 12), fill="black")

        size = estimate_source_vertical_font_size(
            img,
            (20, 20, 140, 200),
            "空腹食事",
        )

        assert size is not None
        assert 10 <= size <= 30

    def test_estimates_larger_source_text_larger(self):
        img = Image.new("RGB", (180, 240), "white")
        draw = ImageDraw.Draw(img)
        for y in range(45, 175, 38):
            draw.rectangle((66, y, 106, y + 28), fill="black")

        size = estimate_source_vertical_font_size(
            img,
            (20, 20, 160, 220),
            "空腹食事",
        )

        assert size is not None
        assert size >= 30

    def test_source_estimate_rejects_dense_artwork(self):
        img = Image.new("RGB", (120, 120), (40, 40, 40))

        assert estimate_source_vertical_font_size(
            img,
            (10, 10, 110, 110),
            "空腹",
        ) is None


class TestMaskSafeBBox:
    """Mask-safe vertical text bounds should not over-shrink jagged bubbles."""

    def test_vertical_uses_more_jagged_mask_width_than_horizontal(self):
        mask = np.zeros((120, 100), dtype=np.uint8)
        for y in range(10, 110):
            if y % 4 < 2:
                mask[y, 5:95] = 255
            else:
                mask[y, 20:80] = 255

        horizontal = _mask_safe_bbox((0, 0, 100, 120), mask, vertical=False)
        vertical = _mask_safe_bbox((0, 0, 100, 120), mask, vertical=True)

        assert vertical[0] < horizontal[0]
        assert vertical[2] > horizontal[2]
        assert vertical[3] - vertical[1] > horizontal[3] - horizontal[1]


class TestBrightRegionExpansion:
    """No-mask furigana should use nearby white caption/glow space."""

    def test_expands_tight_text_box_to_bright_region(self):
        img = Image.new("RGB", (140, 180), (90, 90, 90))
        draw = ImageDraw.Draw(img)
        draw.rectangle((25, 20, 105, 160), fill=(245, 245, 245))

        expanded = _expand_bright_region_bbox(
            img,
            (55, 65, 75, 125),
            min_extra_row_height=30,
        )

        assert expanded[0] <= 26
        assert expanded[1] <= 21
        assert expanded[2] >= 104
        assert expanded[3] >= 159

    def test_leaves_box_when_no_bright_region_overlaps(self):
        img = Image.new("RGB", (100, 100), (80, 80, 80))
        bbox = (40, 30, 60, 70)

        assert _expand_bright_region_bbox(img, bbox) == bbox

    def test_caps_large_bright_background_expansion(self):
        img = Image.new("RGB", (400, 500), (245, 245, 245))
        bbox = (190, 220, 210, 280)

        expanded = _expand_bright_region_bbox(
            img,
            bbox,
            min_extra_row_height=30,
        )

        assert expanded[0] <= bbox[0]
        assert expanded[1] <= bbox[1]
        assert expanded[2] >= bbox[2]
        assert expanded[3] >= bbox[3]
        assert expanded[2] - expanded[0] <= 140
        assert expanded[3] - expanded[1] <= 180

    def test_requires_an_extra_vertical_row_of_border_space(self):
        img = Image.new("RGB", (140, 180), (90, 90, 90))
        draw = ImageDraw.Draw(img)
        draw.rectangle((25, 20, 105, 160), fill=(245, 245, 245))
        bbox = (55, 35, 75, 145)

        assert _expand_bright_region_bbox(
            img,
            bbox,
            min_extra_row_height=40,
        ) == bbox

    def test_rejects_normal_balloons_with_other_text_in_border_space(self):
        img = Image.new("RGB", (220, 220), (90, 90, 90))
        draw = ImageDraw.Draw(img)
        draw.rectangle((25, 20, 195, 200), fill=(245, 245, 245))
        # Simulate neighboring vertical text columns inside the same balloon.
        for x in (55, 135):
            draw.rectangle((x, 55, x + 9, 165), fill=(20, 20, 20))
            draw.rectangle((x + 18, 70, x + 25, 150), fill=(20, 20, 20))
        bbox = (92, 80, 112, 140)

        assert _expand_bright_region_bbox(
            img,
            bbox,
            min_extra_row_height=30,
        ) == bbox


class TestWordWrap:
    """Test word wrapping only breaks words when they don't fit."""

    def test_short_text_single_line(self):
        draw, font = _make_draw_and_font(16)
        lines = _word_wrap("Hi", font, 500, draw)
        assert lines == ["Hi"]

    def test_wraps_at_word_boundary(self):
        draw, font = _make_draw_and_font(16)
        lines = _word_wrap("one two three four five six", font, 100, draw)
        assert len(lines) > 1
        # No hyphens in output — words fit without breaking
        for line in lines:
            assert "-" not in line, f"Unexpected hyphen in '{line}'"

    def test_breaks_long_word_with_hyphen(self):
        draw, font = _make_draw_and_font(16)
        # Very narrow width forces word to break
        lines = _word_wrap("corresponding", font, 40, draw)
        assert len(lines) > 1
        # At least one fragment should have a hyphen (except last)
        has_hyphen = any("-" in line for line in lines[:-1])
        assert has_hyphen, f"Expected hyphen in broken word, got: {lines}"

    def test_no_premature_hyphenation(self):
        """Words should NOT be pre-hyphenated when they fit on a line."""
        draw, font = _make_draw_and_font(14)
        # Wide enough to fit "corresponding" without breaking
        lines = _word_wrap("corresponding", font, 500, draw)
        assert lines == ["corresponding"], f"Should not hyphenate, got: {lines}"
