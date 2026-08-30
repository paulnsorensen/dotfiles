# TypeScript / JavaScript (Jest/Vitest) Weak Assertions

## 1. `toBeTruthy()` / `toBeDefined()` / `not.toBeNull()`

The truthy trifecta. All three avoid asserting the actual value.

```typescript
// WEAK — 0, "", false all fail; "wrong answer" passes
expect(result).toBeTruthy();
expect(result).toBeDefined();
expect(result).not.toBeNull();
expect(result).not.toBeUndefined();

// STRONG
expect(result).toEqual({ id: 1, name: "Alice", role: "admin" });
expect(result).toBe(42);
```

## 2. `toHaveLength()` without content check

Knows the array has items, doesn't know what they are.

```typescript
// WEAK
expect(items).toHaveLength(3);
expect(items.length).toBeGreaterThan(0);

// STRONG — full content
expect(items).toEqual([
  { id: 1, name: "first" },
  { id: 2, name: "second" },
  { id: 3, name: "third" },
]);
```

## 3. `toThrow()` without type or message

Any thrown value passes — wrong error, wrong message, doesn't matter.

```typescript
// WEAK
expect(() => fn()).toThrow();
await expect(promise).rejects.toBeTruthy();

// STRONG — type AND message
expect(() => fn()).toThrow(ValidationError);
expect(() => fn()).toThrow("must be positive");
await expect(promise).rejects.toThrow(NetworkError);

// STRONG — if you need to inspect the error
try {
  fn();
  fail("expected to throw");
} catch (err) {
  expect(err).toBeInstanceOf(ValidationError);
  expect((err as ValidationError).field).toBe("email");
}
```

## 4. `toHaveBeenCalled()` without argument check

The mock was invoked — with what arguments?

```typescript
// WEAK
expect(mockFn).toHaveBeenCalled();
expect(mockFn).toHaveBeenCalledTimes(1);

// STRONG
expect(mockSend).toHaveBeenCalledWith({
  to: "alice@example.com",
  subject: "Welcome",
});
expect(mockSend).toHaveBeenCalledTimes(1); // OK after argument check
```

## 5. `typeof` check — the `null` trap

`typeof null === "object"` in JavaScript. This classic gotcha catches AI regularly.

```typescript
// WEAK — null passes as "object"!
expect(typeof result).toBe("object");
expect(Array.isArray(result)).toBe(true); // empty array passes

// STRONG
expect(result).toEqual({ key: "value" });
expect(result).toEqual(["a", "b", "c"]);
```

## 6. `toMatchSnapshot()` as first resort

Snapshots are fragile, hard to review, and drift over time. They test
formatting, not behavior.

```typescript
// WEAK — snapshot drift, opaque failures
expect(result).toMatchSnapshot();
expect(JSON.stringify(result)).toMatchSnapshot();

// STRONG — explicit structural check
expect(result).toEqual({
  id: expect.any(Number),
  name: "Alice",
  createdAt: expect.any(Date),
});
```

Use snapshots only for large output where manually writing the expected value
is impractical (rendered HTML, complex serialized formats).

## 7. Testing the mock, not the code

Asserts that `jest.fn()` works as configured. Tautological.

```typescript
// WEAK
const mock = jest.fn().mockReturnValue(42);
expect(mock()).toBe(42); // Tests jest, not your code

// STRONG — test the system under test
const mockRepo = { findUser: jest.fn().mockReturnValue(user) };
const service = new UserService(mockRepo);
expect(service.getDisplayName(1)).toBe("Alice");
expect(mockRepo.findUser).toHaveBeenCalledWith(1);
```

## 8. Missing `await` on async assertions

The assertion never executes. The test passes silently.

```typescript
// WEAK — promise is never awaited, assertion doesn't run!
expect(fetchUser(42)).resolves.toEqual(user);
expect(fetchUser(-1)).rejects.toThrow();

// STRONG — always await
await expect(fetchUser(42)).resolves.toEqual(user);
await expect(fetchUser(-1)).rejects.toThrow(NotFoundError);
```

## 9. `toContain()` for structured data

Substring matching on strings or loose `includes` on arrays.

```typescript
// WEAK — "error" might match "error_code", "no_error", etc.
expect(message).toContain("error");
expect(items).toContain(expected); // reference equality trap

// STRONG — exact match or toMatchObject for partials
expect(message).toBe("Validation error: email is required");
expect(items).toContainEqual({ id: 1, name: "Alice" }); // deep equality
```
