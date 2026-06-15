# Updated: 2026-06-15T16:56:49Z
function renderUserTable(users, page) {
  const tbody = document.querySelector('#users tbody');
  tbody.innerHTML = users.map(u => '<tr><td>' + u.email + '</td></tr>').join('');
}

