# Cheese Flair Bank

The full names + quote bank used by `claude/lib/cheese-flair.sh`. The
SessionStart hook samples from this file each session so the principal
`CLAUDE.md` stays slim.

Browse: `bat ~/.claude/reference/cheese-flair.md`.
Sample: `bash ~/.claude/lib/cheese-flair.sh sample`.

## Big hitters

The tight favorites pool — pulled by `cheese_name weighted` (the default
mode used by the SessionStart hook). Roughly 50% of weighted draws return
**Cheese Lord** (handled in the lib, not listed here), 25% return one of
these, 25% pull from the wider bank.

- Big Cheese
- Cheddar King
- The Cheesiah
- Don Curdleone

## Curated names

- Cheese Lord
- Big Cheese
- Big Wheel
- Top Curd
- Head Cheese
- Cheddar King
- Gouda Emperor
- Brie Majesty
- Sultan of Stilton
- Pharaoh of Parmesan
- Tsar of Curds
- Khan of Camembert
- Maharaja of Manchego
- Shogun of Stilton
- Doge of Dairy
- Margrave of Mozzarella
- The Cheesiah
- Curdinal
- Archbishop of Aged Goods
- The Affineur Supreme
- High Pontiff of Pasteur
- Don Curdleone
- Captain Camembert
- Brie-zus
- The Fromage Sage

## Generator pools

`cheese_generate_name` mashes one Adjective + one Title (with `{C}`
replaced by a Cheese) into a fresh title each call.

### Adjectives

- Aged
- Smoldering
- Rancid
- Pungent
- Crusted
- Marbled
- Veined
- Brined
- Cultured
- Whey-Stained
- Curd-Crusted
- Wax-Sealed
- Cave-Dwelling
- Holy
- Heretical
- Sharp
- Sacred
- Forbidden
- Eternal
- Chrome
- Glorious
- Ripening

### Cheeses

- Cheddar
- Brie
- Gouda
- Stilton
- Roquefort
- Camembert
- Manchego
- Mozzarella
- Gruyère
- Parmesan
- Wensleydale
- Halloumi
- Munster
- Limburger
- Pecorino
- Provolone
- Asiago
- Havarti
- Feta
- Emmental
- Comté

### Title formats

- Lord of {C}
- Sultan of {C}
- Pharaoh of {C}
- Tsar of {C}
- Khan of {C}
- Maharaja of {C}
- Shogun of {C}
- Doge of {C}
- Margrave of {C}
- Archbishop of {C}
- Pontiff of {C}
- Don {C}
- Captain {C}
- {C} Lord
- {C} King
- {C} Emperor
- High Curdinal of {C}

## Quotes

### Dune

- "The cheese must flow."
- "He who controls the cheese controls the universe."
- "Fear is the curd-killer. Fear is the little curd that brings total cheese obliteration. I will face my cheese."
- "Bless the Cheesemaker, and his cheese. May his passage cleanse the world."
- "Wheels within wheels within wheels."
- "The sleeper must ripen."
- "Stir without rhythm and you won't break the curd."
- "An aging is a very delicate time."
- "Tell me of your fromagerie, Usul."
- "Curds are messages from the cave."

### Mad Max: Fury Road

- "I age, I rind, I age again."
- "Witness this curd!"
- "Oh what a day, what a lovely cheese day!"
- "Shiny and curd."
- "Age eternal, shiny and curd."
- "Mediocre!"
- "Where must we go, we who wander this wasteland, in search of our better cheese?"
- "Fang it!"
- "Do not, my friends, become addicted to cheese. It will take hold of you and you will resent its absence."

### Monty Python's Holy Grail

- "We are the Knights Who Say… Brie!"
- "None shall pasteurize."
- "'Tis but a scratch on the rind."
- "Bring out your curds!"
- "I'm not curd yet!"
- "Strange women lying in vats distributing cheese is no basis for a system of government."
- "Your mother was a hamster and your father smelt of Limburger."
- "We want… a Wensleydale!"

### The Princess Bride

- "Hello. My name is Inigo Montoya. You killed my Camembert. Prepare to die."
- "I do not think that cheese means what you think it means."

### The Lord of the Rings

- "One Cheese to rule them all."
- "You shall not pasteurize!"
- "My precious… cheese."
- "Not all those who wander are aged."
- "All we have to decide is what cheese to eat with the time that is given us."
