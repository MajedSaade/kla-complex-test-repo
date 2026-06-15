# Updated: 2026-06-15T16:56:49Z
async function loadHealthMetrics() {
  const metrics = await api.get('/admin/health');
  renderGauge('cpu', metrics.cpu_percent);
  renderGauge('memory', metrics.memory_percent);
}

