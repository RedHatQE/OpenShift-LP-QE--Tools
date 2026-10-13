//go:build unit

package main

import "testing"

// TestEnvBool exercises the bot's boolean environment consumer across unset,
// empty, valid, and invalid inputs. An unset variable reads the same as an
// empty one (os.Getenv returns "" for both), so an empty value covers the
// "unset" branch.
func TestEnvBool(t *testing.T) {
	const key = "PROW_AN__TEST__BOOL"
	cases := []struct {
		name string
		env  string
		def  bool
		want bool
	}{
		{"empty/unset returns default true", "", true, true},
		{"empty/unset returns default false", "", false, false},
		{"true enables", "true", false, true},
		{"1 enables", "1", false, true},
		{"TRUE enables", "TRUE", false, true},
		{"false disables", "false", true, false},
		{"0 disables", "0", true, false},
		{"invalid returns default", "notabool", true, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Setenv(key, c.env)
			if got := envBool(key, c.def); got != c.want {
				t.Errorf("envBool(%q, def=%v) = %v, want %v", c.env, c.def, got, c.want)
			}
		})
	}
}

// TestEnvInt exercises the bot's integer environment consumer, including the
// invalid and negative inputs that must fall back to the default.
func TestEnvInt(t *testing.T) {
	const key = "PROW_AN__TEST__INT"
	cases := []struct {
		name string
		env  string
		def  int
		want int
	}{
		{"empty/unset returns default", "", 1200, 1200},
		{"positive parses", "42", 1200, 42},
		{"zero parses", "0", 1200, 0},
		{"negative parses", "-5", 1200, -5},
		{"non-numeric returns default", "abc", 1200, 1200},
		{"float returns default", "1.5", 1200, 1200},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Setenv(key, c.env)
			if got := envInt(key, c.def); got != c.want {
				t.Errorf("envInt(%q, def=%v) = %v, want %v", c.env, c.def, got, c.want)
			}
		})
	}
}

// TestEnvStr exercises the bot's string environment consumer: a set, non-empty
// value wins; an unset or empty value yields the default.
func TestEnvStr(t *testing.T) {
	const key = "PROW_AN__TEST__STR"
	cases := []struct {
		name string
		env  string
		def  string
		want string
	}{
		{"empty/unset returns default", "", "fallback", "fallback"},
		{"set value wins", "custom", "fallback", "custom"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Setenv(key, c.env)
			if got := envStr(key, c.def); got != c.want {
				t.Errorf("envStr(%q, def=%q) = %q, want %q", c.env, c.def, got, c.want)
			}
		})
	}
}
