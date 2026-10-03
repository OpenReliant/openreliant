local ui = require("openreliant.ui")

return {
    engine_handlers = {
        on_frame = function()
            if not ui.shown then return end
            local style = { font = "menu_large", scale = 1 }
            -- A custom outline keeps the chosen base font's spacing and fallback glyphs.
            if pcall(ui.measure, "Drawing assets", { font = "title.ttf", base_font = "menu_large" }) then
                style = { font = "title.ttf", base_font = "menu_large" }
            end
            local size = ui.measure("Drawing assets", style)
            ui.text(vector.create(20, 20, 0), "Drawing assets", style)
            pcall(ui.picture, vector.create(20, 30 + size.height, 0), "badge.png", vector.create(64, 64, 0))
            -- Sets differ between screens, so this optional shape may not be available.
            pcall(ui.shape, vector.create(110, 30 + size.height, 0), 1)
        end,
    },
}
