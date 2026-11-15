package auth

import (
	"testing"

	"golang.org/x/crypto/bcrypt"
)

func hashOf(t *testing.T, password string) string {
	t.Helper()
	h, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.MinCost)
	if err != nil {
		t.Fatal(err)
	}
	return string(h)
}

func TestPasswordChangedFromDefault(t *testing.T) {
	def := hashOf(t, "admin")
	other := hashOf(t, "s3cret")

	for i := 0; i < 2; i++ { // the second round is answered from the cache
		if passwordChangedFromDefault(def) {
			t.Fatalf("round %d: default password reported as changed", i)
		}
	}
	if !passwordChangedFromDefault(other) {
		t.Fatal("new password not reported as changed")
	}
	if !passwordChangedFromDefault(other) {
		t.Fatal("cached answer for new password lost")
	}
	if passwordChangedFromDefault(def) {
		t.Fatal("going back to the default hash not re-checked")
	}
	// A malformed hash is not a changed password, as before.
	if passwordChangedFromDefault("not-a-hash") {
		t.Fatal("malformed hash reported as changed")
	}
}
