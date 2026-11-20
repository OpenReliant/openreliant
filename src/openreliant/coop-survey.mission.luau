mission({ name = "Relay Survey" })

crew = flight_group("(FG)Survey Crew")
relays = flight_group("(FG)Survey Relays")

lead = ship("Survey One", {
    type = "predator", group = crew, position = { -9500, 0, 0 },
})
wing = ship("Survey Two", {
    type = "predator", group = crew, position = { 9500, 0, 0 },
})
reserve = ship("Survey Three", {
    type = "predator", group = crew, position = { 0, 0, -5000 },
})
west = ship("West Relay", {
    type = "satellite", group = relays, position = { -9500, 3000, 26000 },
})
east = ship("East Relay", {
    type = "satellite", group = relays, position = { 9500, 3000, 41000 },
})

scanned = global("(GV)Relays scanned", 0)

survey = handler(function()
    scanned += 1
    game.objectives_met = scanned
    if scanned == 2 then
        game.mission_success = 3
        game.mission_over = 1
    end
    return 1
end)

on(west, "proximity_general", { approaching_ship = any_ship, proximity = 20 }, survey)
on(east, "proximity_general", { approaching_ship = any_ship, proximity = 20 }, survey)

timeout = part("(F)Survey Timeout", function()
    game.mission_success = scanned
    game.mission_over = 1
    return 1
end)

start = part("(F)Start", function()
    CreateFlightGroup(crew)
    CreateFlightGroup(relays)
    CreateTimer(1, timeout, 120, 1)
    return 1
end, { start = true })
