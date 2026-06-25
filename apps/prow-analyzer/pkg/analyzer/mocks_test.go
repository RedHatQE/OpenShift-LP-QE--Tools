package analyzer

import (
	"context"
	"errors"
	"io"
	"net/http"
)

// mockHTTPClient implements HTTPDoer for testing
type mockHTTPClient struct {
	doFunc func(req *http.Request) (*http.Response, error)
}

func (m *mockHTTPClient) Do(req *http.Request) (*http.Response, error) {
	if m.doFunc != nil {
		return m.doFunc(req)
	}
	return nil, errors.New("mock not configured")
}

// mockJSONMarshal is a failing JSON marshaler for testing error paths
func mockJSONMarshalError(v interface{}) ([]byte, error) {
	return nil, errors.New("mock json.Marshal error")
}

// mockNewRequestError is a failing request builder for testing error paths
func mockNewRequestError(ctx context.Context, method, url string, body io.Reader) (*http.Request, error) {
	return nil, errors.New("mock http.NewRequestWithContext error")
}

// errorReader is an io.ReadCloser that always returns an error
type errorReader struct{}

func (e *errorReader) Read(p []byte) (n int, err error) {
	return 0, errors.New("mock read error")
}

func (e *errorReader) Close() error {
	return nil
}
