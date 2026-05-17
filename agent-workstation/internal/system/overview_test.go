package system

import "testing"

func TestParseMemInfo(t *testing.T) {
	mem, err := ParseMemInfo(`MemTotal:       16384000 kB
MemFree:         4096000 kB
MemAvailable:   8192000 kB
`)
	if err != nil {
		t.Fatalf("ParseMemInfo returned error: %v", err)
	}
	if mem.TotalBytes != 16777216000 {
		t.Fatalf("unexpected total bytes: %d", mem.TotalBytes)
	}
	if mem.AvailableBytes != 8388608000 {
		t.Fatalf("unexpected available bytes: %d", mem.AvailableBytes)
	}
	if mem.UsedPercent != 50 {
		t.Fatalf("expected used percent 50, got %.2f", mem.UsedPercent)
	}
}

func TestParseLoadAverage(t *testing.T) {
	load, err := ParseLoadAverage("0.12 0.34 0.56 1/234 5678\n")
	if err != nil {
		t.Fatalf("ParseLoadAverage returned error: %v", err)
	}
	if load.One != 0.12 || load.Five != 0.34 || load.Fifteen != 0.56 {
		t.Fatalf("unexpected load values: %#v", load)
	}
}

func TestParseCPUInfoCountsProcessors(t *testing.T) {
	count := ParseCPUInfo(`processor   : 0
vendor_id   : GenuineIntel
processor   : 1
processor   : 2
`)
	if count != 3 {
		t.Fatalf("expected 3 processors, got %d", count)
	}
}

func TestParseUptime(t *testing.T) {
	uptime, err := ParseUptime("3661.25 100.00\n")
	if err != nil {
		t.Fatalf("ParseUptime returned error: %v", err)
	}
	if uptime.Seconds != 3661 {
		t.Fatalf("expected 3661 seconds, got %d", uptime.Seconds)
	}
	if uptime.Display != "1h 1m" {
		t.Fatalf("expected display 1h 1m, got %q", uptime.Display)
	}
}

func TestParseDFOutput(t *testing.T) {
	disk, err := ParseDFOutput("10737418240 5368709120 5368709120 50% /\n")
	if err != nil {
		t.Fatalf("ParseDFOutput returned error: %v", err)
	}
	if disk.TotalBytes != 10737418240 {
		t.Fatalf("unexpected total bytes: %d", disk.TotalBytes)
	}
	if disk.UsedPercent != 50 {
		t.Fatalf("unexpected used percent: %.2f", disk.UsedPercent)
	}
}
