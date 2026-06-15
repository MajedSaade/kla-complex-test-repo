# Updated: 2026-06-15T16:56:49Z
function exportAuditLog(filters) {
  return api.get('/admin/audit/export', { params: filters, responseType: 'blob' });
}

