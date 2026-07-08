/// Wapuro-style romaji → hiragana conversion, so a furigana reading can be
/// typed with a plain keyboard (no system IME). Type `tabe` -> たべ,
/// `nihongo` -> にほんご. Use double `n` ("nn") for a standalone ん.
///
/// Characters that aren't romaji (already-kana, spaces, kanji) pass through,
/// and a trailing incomplete syllable is left as-is so it converts once the
/// next letter arrives.
library;

const Map<String, String> _syllables = {
  // vowels
  'a': 'あ', 'i': 'い', 'u': 'う', 'e': 'え', 'o': 'お',
  // k / g
  'ka': 'か', 'ki': 'き', 'ku': 'く', 'ke': 'け', 'ko': 'こ',
  'ga': 'が', 'gi': 'ぎ', 'gu': 'ぐ', 'ge': 'げ', 'go': 'ご',
  'kya': 'きゃ', 'kyu': 'きゅ', 'kyo': 'きょ',
  'gya': 'ぎゃ', 'gyu': 'ぎゅ', 'gyo': 'ぎょ',
  // s / z
  'sa': 'さ', 'shi': 'し', 'si': 'し', 'su': 'す', 'se': 'せ', 'so': 'そ',
  'za': 'ざ', 'ji': 'じ', 'zi': 'じ', 'zu': 'ず', 'ze': 'ぜ', 'zo': 'ぞ',
  'sha': 'しゃ', 'shu': 'しゅ', 'sho': 'しょ',
  'sya': 'しゃ', 'syu': 'しゅ', 'syo': 'しょ',
  'ja': 'じゃ', 'ju': 'じゅ', 'jo': 'じょ',
  'jya': 'じゃ', 'jyu': 'じゅ', 'jyo': 'じょ',
  // t / d
  'ta': 'た', 'chi': 'ち', 'ti': 'ち', 'tsu': 'つ', 'tu': 'つ',
  'te': 'て', 'to': 'と',
  'da': 'だ', 'di': 'ぢ', 'du': 'づ', 'de': 'で', 'do': 'ど',
  'cha': 'ちゃ', 'chu': 'ちゅ', 'cho': 'ちょ',
  'tya': 'ちゃ', 'tyu': 'ちゅ', 'tyo': 'ちょ',
  // n
  'na': 'な', 'ni': 'に', 'nu': 'ぬ', 'ne': 'ね', 'no': 'の',
  'nya': 'にゃ', 'nyu': 'にゅ', 'nyo': 'にょ',
  // h / b / p
  'ha': 'は', 'hi': 'ひ', 'fu': 'ふ', 'hu': 'ふ', 'he': 'へ', 'ho': 'ほ',
  'ba': 'ば', 'bi': 'び', 'bu': 'ぶ', 'be': 'べ', 'bo': 'ぼ',
  'pa': 'ぱ', 'pi': 'ぴ', 'pu': 'ぷ', 'pe': 'ぺ', 'po': 'ぽ',
  'hya': 'ひゃ', 'hyu': 'ひゅ', 'hyo': 'ひょ',
  'bya': 'びゃ', 'byu': 'びゅ', 'byo': 'びょ',
  'pya': 'ぴゃ', 'pyu': 'ぴゅ', 'pyo': 'ぴょ',
  // m
  'ma': 'ま', 'mi': 'み', 'mu': 'む', 'me': 'め', 'mo': 'も',
  'mya': 'みゃ', 'myu': 'みゅ', 'myo': 'みょ',
  // y / r / w
  'ya': 'や', 'yu': 'ゆ', 'yo': 'よ',
  'ra': 'ら', 'ri': 'り', 'ru': 'る', 're': 'れ', 'ro': 'ろ',
  'rya': 'りゃ', 'ryu': 'りゅ', 'ryo': 'りょ',
  'wa': 'わ', 'wo': 'を',
  // small vowels + long mark
  'la': 'ぁ', 'li': 'ぃ', 'lu': 'ぅ', 'le': 'ぇ', 'lo': 'ぉ',
  '-': 'ー',
};

const String _vowels = 'aeiou';
const String _consonants = 'bcdfghjkmpqrstvwxyz'; // no 'n' (special) or 'l'

String romajiToHiragana(String input) {
  final s = input.toLowerCase();
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final c = s[i];

    // Pass through anything that isn't romaji (already kana, kanji, spaces).
    if (!_isRomaji(c)) {
      out.write(input[i]); // keep original case/char for non-romaji
      i++;
      continue;
    }

    // Sokuon: doubled consonant (e.g. "kk") -> っ + consonant.
    if (i + 1 < s.length &&
        c == s[i + 1] &&
        _consonants.contains(c) &&
        c != 'n') {
      out.write('っ');
      i++;
      continue;
    }

    // Greedy longest match (3, 2, 1) against the syllable table.
    var matched = false;
    for (final len in const [3, 2, 1]) {
      if (i + len <= s.length) {
        final chunk = s.substring(i, i + len);
        final kana = _syllables[chunk];
        if (kana != null) {
          out.write(kana);
          i += len;
          matched = true;
          break;
        }
      }
    }
    if (matched) continue;

    // Standalone 'n': "nn" or 'n' before a consonant -> ん. A trailing 'n'
    // is left so "na"/"ni"/... still work when the next letter is typed.
    if (c == 'n') {
      final next = i + 1 < s.length ? s[i + 1] : '';
      if (next == 'n') {
        out.write('ん');
        i += 2;
        continue;
      }
      if (next.isNotEmpty && !_vowels.contains(next) && next != 'y') {
        out.write('ん');
        i++;
        continue;
      }
    }

    // Unmatched (incomplete syllable) — leave as typed.
    out.write(input[i]);
    i++;
  }
  return out.toString();
}

bool _isRomaji(String c) {
  final code = c.codeUnitAt(0);
  return (code >= 0x61 && code <= 0x7a) || c == '-'; // a-z or long mark
}
