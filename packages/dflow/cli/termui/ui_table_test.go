package termui

import (
	"bytes"
	"strings"
	"testing"
)

func TestTableKeepsSideBordersAndPipeJunctions(t *testing.T) {
	var buf bytes.Buffer
	ui := NewUI()
	ui.SetOutput(&buf)

	ui.Normal().
		Compact().
		KeepLine().
		WithTable("Name", "Created", "Status").
		WithTableRow("whoami", "2026-10-23", "1/1").
		WithTableRow("api", "2026-01-02", "n/a").
		Msg("")

	got := buf.String()
	want := "" +
		"|  NAME  |  CREATED   | STATUS |\n" +
		"|--------|------------|--------|\n" +
		"| whoami | 2026-10-23 | 1/1    |\n" +
		"| api    | 2026-01-02 | n/a    |\n"
	if !strings.Contains(got, want) {
		t.Fatalf("table output:\n%q\nwant containing:\n%q", got, want)
	}
}
