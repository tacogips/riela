# Utterance matching

`riela/utterance-match` version `1` is a deterministic, offline add-on that
decides whether a transcribed utterance was addressed to the assistant and, if
so, whether it matches a fast-path intent. It is the wake-word check of the
voice assistant (issue #185): there is no wake-word engine, the recorder
transcribes every speech segment and this add-on requires the wake phrase at the
start of the text.

```json
{
  "name": "riela/utterance-match", "version": "1",
  "config": { "options": {
    "text": "{{speechToText.text}}",
    "wakePhrases": ["ねえリエラ", "リエラ", "hey riela"],
    "requireWakePhrase": true,
    "intents": [
      { "id": "aircon_off", "patterns": ["エアコン(を)?(消|け)して", "冷房止めて"] },
      { "id": "lights_on", "patterns": ["電気(を)?つけて", "lights? on"] }
    ]
  } }
}
```

## Normalization

Text and wake phrases are normalized with NFKC, katakana → hiragana, lowercase,
and removal of whitespace and punctuation (`、。！？!?,.・` and similar). The
long-vowel mark `ー` is kept. So `ﾈｴ ﾘｴﾗ`, `ねえ、リエラ` and `ネエリエラ` all
normalize to `ねえりえら`, and `Hey Riela,` to `heyriela`.

Intent patterns are regular expressions applied to the normalized command (the
text after the wake phrase). They get the same NFKC, kana folding and whitespace
removal, and match case-insensitively; full-width Japanese punctuation is
dropped from them, but ASCII punctuation stays regular-expression syntax. A
pattern matches anywhere in the command unless anchored with `^`/`$`.

## Matching

- The longest wake phrase that prefixes the normalized text wins. A wake phrase
  later in the sentence does not count.
- With `requireWakePhrase: false`, intents are matched against the whole text
  when no wake phrase is present.
- Intents are checked in table order; `intent` is the first match and `intents`
  lists every match.

Limits: `text` ≤ 8 KB, ≤ 16 wake phrases, ≤ 64 intents, ≤ 16 patterns per
intent, ≤ 256 characters per phrase or pattern, intent ids `^[a-z0-9_]{1,64}$`.
Invalid regular expressions, duplicate ids and unknown options are
`invalidInput`. `addon.env` is not accepted.

## Output

```json
{ "utterance": {
  "wake": true, "wakePhrase": "ねえリエラ",
  "command": "エアコン消して", "normalizedCommand": "えあこん消して",
  "intent": "aircon_off", "intents": ["aircon_off"],
  "normalized": "ねえりえらえあこん消して", "text": "ねえリエラ、エアコン消して"
} }
```

`command` is the original text after the wake phrase (spacing kept, so it reads
naturally when passed to an LLM fallback). An optional `config.context` value is
copied to the output.

`when` labels: `always`, `wake`, `no_wake`, `intent` (an intent matched),
`freeform` (addressed but no intent matched), and `intent_<id>` for every
declared intent, so a workflow can branch per intent without a separate
`riela/json-route`.

See [Home Assistant](../home-assistant.md) for the fast-path service calls these
intents usually lead to.
