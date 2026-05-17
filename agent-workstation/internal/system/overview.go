package system

import (
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

type Overview struct {
	Hostname string     `json:"hostname"`
	IPs      []string   `json:"ips"`
	CPU      CPUInfo    `json:"cpu"`
	Memory   MemoryInfo `json:"memory"`
	Load     LoadInfo   `json:"load"`
	Uptime   UptimeInfo `json:"uptime"`
	Disk     DiskInfo   `json:"disk"`
}

type CPUInfo struct {
	Cores int `json:"cores"`
}

type MemoryInfo struct {
	TotalBytes     uint64  `json:"totalBytes"`
	AvailableBytes uint64  `json:"availableBytes"`
	UsedPercent    float64 `json:"usedPercent"`
}

type LoadInfo struct {
	One     float64 `json:"one"`
	Five    float64 `json:"five"`
	Fifteen float64 `json:"fifteen"`
}

type UptimeInfo struct {
	Seconds int64  `json:"seconds"`
	Display string `json:"display"`
}

type DiskInfo struct {
	TotalBytes     uint64  `json:"totalBytes"`
	UsedBytes      uint64  `json:"usedBytes"`
	AvailableBytes uint64  `json:"availableBytes"`
	UsedPercent    float64 `json:"usedPercent"`
	Mount          string  `json:"mount"`
}

func CollectOverview() (Overview, error) {
	hostname, _ := os.Hostname()
	memRaw, memErr := os.ReadFile("/proc/meminfo")
	cpuRaw, cpuErr := os.ReadFile("/proc/cpuinfo")
	loadRaw, loadErr := os.ReadFile("/proc/loadavg")
	uptimeRaw, uptimeErr := os.ReadFile("/proc/uptime")
	dfRaw, dfErr := exec.Command("df", "-B1", "--output=size,used,avail,pcent,target", "/").Output()

	var overview Overview
	overview.Hostname = hostname
	overview.IPs = localIPs()

	if memErr == nil {
		overview.Memory, memErr = ParseMemInfo(string(memRaw))
	}
	if cpuErr == nil {
		overview.CPU = CPUInfo{Cores: ParseCPUInfo(string(cpuRaw))}
	}
	if loadErr == nil {
		overview.Load, loadErr = ParseLoadAverage(string(loadRaw))
	}
	if uptimeErr == nil {
		overview.Uptime, uptimeErr = ParseUptime(string(uptimeRaw))
	}
	if dfErr == nil {
		overview.Disk, dfErr = ParseDFOutput(lastLine(string(dfRaw)))
	}

	return overview, errors.Join(memErr, cpuErr, loadErr, uptimeErr, dfErr)
}

func ParseMemInfo(input string) (MemoryInfo, error) {
	values := map[string]uint64{}
	for _, line := range strings.Split(input, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		key := strings.TrimSuffix(fields[0], ":")
		value, err := strconv.ParseUint(fields[1], 10, 64)
		if err != nil {
			return MemoryInfo{}, fmt.Errorf("parse %s: %w", key, err)
		}
		values[key] = value * 1024
	}
	total := values["MemTotal"]
	available := values["MemAvailable"]
	if total == 0 {
		return MemoryInfo{}, errors.New("MemTotal missing")
	}
	usedPercent := float64(total-available) / float64(total) * 100
	return MemoryInfo{TotalBytes: total, AvailableBytes: available, UsedPercent: usedPercent}, nil
}

func ParseLoadAverage(input string) (LoadInfo, error) {
	fields := strings.Fields(input)
	if len(fields) < 3 {
		return LoadInfo{}, errors.New("load average requires three fields")
	}
	one, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return LoadInfo{}, err
	}
	five, err := strconv.ParseFloat(fields[1], 64)
	if err != nil {
		return LoadInfo{}, err
	}
	fifteen, err := strconv.ParseFloat(fields[2], 64)
	if err != nil {
		return LoadInfo{}, err
	}
	return LoadInfo{One: one, Five: five, Fifteen: fifteen}, nil
}

func ParseCPUInfo(input string) int {
	count := 0
	for _, line := range strings.Split(input, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "processor") {
			count++
		}
	}
	if count == 0 {
		return 1
	}
	return count
}

func ParseUptime(input string) (UptimeInfo, error) {
	fields := strings.Fields(input)
	if len(fields) == 0 {
		return UptimeInfo{}, errors.New("uptime requires one field")
	}
	secondsFloat, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return UptimeInfo{}, err
	}
	seconds := int64(secondsFloat)
	return UptimeInfo{Seconds: seconds, Display: formatDuration(seconds)}, nil
}

func ParseDFOutput(input string) (DiskInfo, error) {
	fields := strings.Fields(input)
	if len(fields) < 5 {
		return DiskInfo{}, errors.New("df output requires five fields")
	}
	total, err := strconv.ParseUint(fields[0], 10, 64)
	if err != nil {
		return DiskInfo{}, err
	}
	used, err := strconv.ParseUint(fields[1], 10, 64)
	if err != nil {
		return DiskInfo{}, err
	}
	available, err := strconv.ParseUint(fields[2], 10, 64)
	if err != nil {
		return DiskInfo{}, err
	}
	percentText := strings.TrimSuffix(fields[3], "%")
	percent, err := strconv.ParseFloat(percentText, 64)
	if err != nil {
		return DiskInfo{}, err
	}
	return DiskInfo{
		TotalBytes:     total,
		UsedBytes:      used,
		AvailableBytes: available,
		UsedPercent:    percent,
		Mount:          fields[4],
	}, nil
}

func formatDuration(seconds int64) string {
	days := seconds / 86400
	seconds %= 86400
	hours := seconds / 3600
	seconds %= 3600
	minutes := seconds / 60
	if days > 0 {
		return fmt.Sprintf("%dd %dh", days, hours)
	}
	if hours > 0 {
		return fmt.Sprintf("%dh %dm", hours, minutes)
	}
	return fmt.Sprintf("%dm", minutes)
}

func localIPs() []string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return nil
	}
	var ips []string
	for _, addr := range addrs {
		ipNet, ok := addr.(*net.IPNet)
		if !ok || ipNet.IP.IsLoopback() {
			continue
		}
		ip := ipNet.IP.To4()
		if ip == nil {
			continue
		}
		ips = append(ips, ip.String())
	}
	return ips
}

func lastLine(input string) string {
	lines := strings.Split(strings.TrimSpace(input), "\n")
	if len(lines) == 0 {
		return ""
	}
	return lines[len(lines)-1]
}
