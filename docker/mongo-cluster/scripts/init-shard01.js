rs.initiate({
  _id: 'rs-shard-01',
  version: 1,
  members: [
    { _id: 0, host: 'shard1-primary:27017' },
    { _id: 1, host: 'shard1-secondary-0:27017' },
    { _id: 2, host: 'shard1-secondary-1:27017' },
  ],
})
