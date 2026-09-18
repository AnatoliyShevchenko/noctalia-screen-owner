--!nonstrict
-- Иконка в баре: открывает панель. Вся логика в panel.luau, здесь только
-- точка входа, объявленная в [widget.actions] манифеста.

local function render()
    barWidget.setGlyph("keyboard")
    barWidget.setTooltip(noctalia.tr("title"))
end

render()
