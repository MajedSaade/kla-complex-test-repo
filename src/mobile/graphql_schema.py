# Updated: 2026-06-15T16:56:48Z
type Query {
  userProfile(id: ID!): User
  transactions(limit: Int): [Transaction]
}

