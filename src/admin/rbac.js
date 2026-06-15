# Updated: 2026-06-15T16:56:49Z
const ROLES = ['admin', 'operator', 'viewer'];
function assignRole(userId, role) {
  return api.patch('/admin/users/' + userId + '/role', { role });
}

