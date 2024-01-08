rs.initiate({
  _id: 'rs-shard-02',
  version: 1,
  members: [
    { _id: 0, host: 'shard2-primary:27017' },
    { _id: 1, host: 'shard2-secondary-0:27017' },
    { _id: 2, host: 'shard2-secondary-1:27017' },
  ],
})
