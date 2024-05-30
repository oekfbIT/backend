db.createUser({
    user: "admin",
    pwd: "EF6mecfU-p2GMq",  // change this to a strong password
    roles: [{ role: "root", db: "admin" }]
});
