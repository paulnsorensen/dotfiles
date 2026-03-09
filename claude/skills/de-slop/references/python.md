# Python Anti-Patterns

## 1. `range(len())` instead of `enumerate`

AI defaults to C-style index loops.

```python
# SLOP
for i in range(len(items)):
    print(i, items[i])

# CLEAN
for i, item in enumerate(items):
    print(i, item)
```

When you don't need the index at all, just iterate directly:
```python
for item in items:
    process(item)
```

## 2. Manual `None` checks instead of truthiness

```python
# SLOP
if user is not None and user.name is not None and len(user.name) > 0:
    greet(user.name)

# CLEAN
if user and user.name:
    greet(user.name)
```

## 3. Old-style string formatting

AI mixes `%`, `.format()`, and f-strings inconsistently.

```python
# SLOP
message = "Hello, %s! You have %d messages." % (name, count)
message = "Hello, {}!".format(name)

# CLEAN — f-strings everywhere (Python 3.6+)
message = f"Hello, {name}! You have {count} messages."
```

## 4. Silent `except: pass`

Swallowing exceptions without handling is the #1 debugging time-sink.

```python
# SLOP
try:
    risky_operation()
except Exception:
    pass  # Silent failure — good luck debugging

# CLEAN — either handle it meaningfully or don't catch it
# If you truly need to ignore: except SpecificError as e: logger.debug(...)
```

## 5. Raw dicts for structured data

AI returns `{"id": 1, "name": "Alice"}` where a dataclass gives you
type safety, IDE support, and self-documenting code.

```python
# SLOP
def get_user():
    return {"id": 1, "name": "Alice", "email": "alice@example.com"}

# CLEAN
@dataclass
class User:
    id: int
    name: str
    email: str
```

## 6. `open()` without context manager

```python
# SLOP
f = open("file.txt")
data = f.read()
f.close()  # Never reached if f.read() throws

# CLEAN
with open("file.txt") as f:
    data = f.read()
```

## 7. Overzealous type hints on obvious locals

```python
# SLOP
name: str = "Alice"
count: int = 0
items: list[str] = []
active: bool = True

# CLEAN — type hints on function signatures, not obvious assignments
name = "Alice"
count = 0
items: list[str] = []  # Empty collection annotation is fine (inference can't know the element type)
active = True
```

## 8. List comprehension where a generator suffices

```python
# SLOP — builds entire list in memory just to iterate
total = sum([x * x for x in range(1_000_000)])

# CLEAN — generator expression, lazy evaluation
total = sum(x * x for x in range(1_000_000))
```
