db.createUser({
    user: "admin",
    pwd: "password",  // change this to a strong password
    roles: [{ role: "root", db: "admin" }]
});
