# Go (testing/testify) Weak Assertions

## 1. `require.NoError` as sole assertion

Error absence is necessary but not sufficient. What did the function return?

```go
// WEAK — error checked, result ignored
result, err := service.GetUser(42)
require.NoError(t, err)

// STRONG — error AND value
result, err := service.GetUser(42)
require.NoError(t, err)
assert.Equal(t, &User{ID: 42, Name: "Alice", Role: "admin"}, result)
```

## 2. `assert.Error` without type or message

Any error passes. Wrong query? Passes. Nil pointer? Passes.

```go
// WEAK
_, err := service.GetUser(-1)
assert.Error(t, err)

// STRONG — specific error type
var notFoundErr *NotFoundError
require.ErrorAs(t, err, &notFoundErr)
assert.Equal(t, 42, notFoundErr.ID)

// STRONG — error message
require.ErrorContains(t, err, "user -1 not found")

// STRONG — sentinel error
require.ErrorIs(t, err, ErrNotFound)
```

## 3. Length check without content

```go
// WEAK
assert.Equal(t, 2, len(results))

// STRONG
assert.Equal(t, []User{
    {ID: 1, Name: "Alice"},
    {ID: 2, Name: "Bob"},
}, results)
```

## 4. `t.Fail()` / `t.Error()` without message

Go's test output is minimalist. Without context, failures are cryptic.

```go
// WEAK
if got != expected {
    t.Fail()
}

// WEAK — message but manual comparison (verbose, inconsistent)
if got != expected {
    t.Errorf("got %v, want %v", got, expected)
}

// STRONG — use testify, consistent format, diff on failure
assert.Equal(t, expected, got)
```

## 5. `assert.Nil` on interfaces — the nil interface trap

A non-nil interface holding a nil pointer is not nil. Classic Go gotcha.

```go
// WEAK — this can fail unexpectedly
var err error = (*MyError)(nil) // non-nil interface, nil pointer
assert.Nil(t, err)             // FAILS — err is not nil!

// BETTER — prefer NoError for intent when checking errors
assert.NoError(t, err)         // but still FAILS for typed-nil errors

// REAL FIX — ensure the code under test returns a truly nil error
// return nil, NOT return (*MyError)(nil)
func (s *Service) DoSomething() error {
    if ok {
        return nil // correct: returns nil interface
    }
    return &MyError{} // correct: returns non-nil interface with non-nil pointer
}
```

## 6. Missing `t.Helper()` in test helpers

Stack traces point to the helper function, not the test that called it.

```go
// WEAK
func assertUserEquals(t *testing.T, got, want User) {
    assert.Equal(t, want, got) // failure points HERE, not the caller
}

// STRONG
func assertUserEquals(t *testing.T, got, want User) {
    t.Helper() // failure points to the calling test
    assert.Equal(t, want, got)
}
```

## 7. Sequential subtests instead of table-driven

AI writes repetitive sequential test cases instead of Go's idiomatic
table-driven pattern.

```go
// WEAK — repetitive, hard to add cases
func TestFormat(t *testing.T) {
    result1, _ := format(1)
    assert.Equal(t, "1 item", result1)
    result2, _ := format(0)
    assert.Equal(t, "0 items", result2)
    _, err3 := format(-1)
    assert.Error(t, err3) // not even consistent with above
}

// STRONG — table-driven
func TestFormat(t *testing.T) {
    tests := []struct {
        name    string
        input   int
        want    string
        wantErr bool
    }{
        {"singular", 1, "1 item", false},
        {"plural", 0, "0 items", false},
        {"negative", -1, "", true},
    }
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            got, err := format(tt.input)
            if tt.wantErr {
                require.Error(t, err)
                return
            }
            require.NoError(t, err)
            assert.Equal(t, tt.want, got)
        })
    }
}
```

## 8. `fmt.Sprintf("%v")` for comparison

Comparing string representations instead of structured values.

```go
// WEAK — Debug repr comparison
assert.Contains(t, fmt.Sprintf("%v", result), "Alice")

// STRONG — structural equality
assert.Equal(t, expected, result)
```

## 9. Missing `t.Parallel()`

AI generates serial tests by default. Independent tests should run in parallel.

```go
// WEAK — serial, slow
func TestGetUser(t *testing.T) {
    // ...
}

// STRONG — parallel where tests are independent
func TestGetUser(t *testing.T) {
    t.Parallel()
    // ...
}
```
