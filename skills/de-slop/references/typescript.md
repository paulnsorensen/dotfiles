# TypeScript / JavaScript Anti-Patterns

## 1. `any` as escape hatch

When types get complex, AI gives up and uses `any`, throwing away
everything TypeScript provides.

```typescript
// SLOP
function processData(data: any): any {
  return data.value;
}

// CLEAN
function processData<T extends { value: unknown }>(data: T): T['value'] {
  return data.value;
}

// Or if you genuinely don't know the shape:
function processData(data: unknown): unknown {
  if (hasValue(data)) return data.value;
  throw new Error("missing value field");
}
```

## 2. `.then()` chains instead of `async/await`

AI mixes paradigms or uses promise chains where async/await is cleaner.

```typescript
// SLOP
function fetchUser(id: string) {
  return fetch(`/api/users/${id}`)
    .then(res => res.json())
    .then(data => data.user)
    .catch(err => console.error(err));
}

// CLEAN
async function fetchUser(id: string): Promise<User> {
  const res = await fetch(`/api/users/${id}`);
  return (await res.json()).user;
  // Let errors propagate — the caller should decide what to do
}
```

## 3. `console.log` debugging left in

AI adds debug logging that never gets removed.

```typescript
// SLOP
console.log("Fetching user...");
const user = await fetchUser(id);
console.log("User fetched:", user);
console.log("Processing...");
```

**Fix:** Delete all `console.log` debug statements. Use a proper logger
if observability is needed, or remove entirely if the code is
self-evident.

## 4. `Array.forEach` with async callbacks

`forEach` doesn't await — async callbacks fire and are silently dropped.

```typescript
// SLOP — these await calls do nothing useful
items.forEach(async (item) => {
  await processItem(item);  // Runs concurrently, forEach doesn't wait
});

// CLEAN — sequential
for (const item of items) {
  await processItem(item);
}

// CLEAN — concurrent with control
await Promise.all(items.map(item => processItem(item)));
```

## 5. Redundant null checks TypeScript already handles

With `strictNullChecks`, the compiler enforces null safety.

```typescript
// SLOP — name can't be undefined here, the type says string | null
function greet(name: string | null): string {
  if (name === null || name === undefined) {
    return "Hello, stranger";
  }
  return `Hello, ${name}`;
}

// CLEAN
function greet(name: string | null): string {
  return name ? `Hello, ${name}` : "Hello, stranger";
}
```

## 6. `JSON.parse(JSON.stringify())` for deep cloning

```typescript
// SLOP
const cloned = JSON.parse(JSON.stringify(user));

// CLEAN — structuredClone (available in all modern runtimes)
const cloned = structuredClone(user);
```

## 7. Redundant type annotations on initialized variables

```typescript
// SLOP
const count: number = 0;
const name: string = user.name;
const isActive: boolean = true;
const users: User[] = getUsers();

// CLEAN — inference handles these
const count = 0;
const name = user.name;
const isActive = true;
const users = getUsers();  // Return type already typed

// Keep annotations on empty collections or ambiguous initializers
const users: User[] = [];
```

## 8. Over-importing from barrel files

```typescript
// SLOP — grabs everything, bloats bundle
import { UserService, UserModel, UserDTO, UserMapper, UserValidator } from "./users";

// CLEAN — import only what you use
import { UserService } from "./users";
```
