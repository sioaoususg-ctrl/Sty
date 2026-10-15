-- language: Lua, file: sunhub.lua, target: Roblox Executor
-- game: Ride & Steal Eggs (PlaceId 15448459363)
-- hub: SunHub — icons pulled from game StarterGui at runtime
-- systems: pet dropdown (ride selector), auto-steal loop, ESP, speed boost, status

--------------------------------------------------------
-- SERVICES & LOCALS
--------------------------------------------------------
local Players        = game:GetService("Players")
local RunService     = game:GetService("RunService")
local TweenService   = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")
local mouse       = localPlayer:GetMouse()

--------------------------------------------------------
-- ICON HELPER  (pulls Image from live game UI)
--------------------------------------------------------
local StarterGui = game:GetService("StarterGui")

local function safeImg(path)
    local ok, img = pcall(function() return path.Image end)
    return (ok and type(img) == "string") and img or "rbxassetid://0"
end

-- read icons lazily from the game's own HUD
local _hud   = StarterGui:FindFirstChild("GameUI") and StarterGui.GameUI:FindFirstChild("HUD")
local _left  = _hud and _hud:FindFirstChild("LeftMenu")
local _right = _hud and _hud:FindFirstChild("RightMenu")
local _back  = StarterGui:FindFirstChild("Backpack") and StarterGui.Backpack:FindFirstChild("Bag")

local ICO = {
    pets     = _right and safeImg(_right.Pets.Icon)     or "rbxassetid://0",
    eggs     = _right and safeImg(_right.Eggs.Icon)     or "rbxassetid://0",
    shop     = _left  and safeImg(_left.Shop.Icon)      or "rbxassetid://0",
    settings = _left  and safeImg(_left.Settings.Icon)  or "rbxassetid://0",
    index    = _left  and safeImg(_left.Index.Icon)     or "rbxassetid://0",
}

--------------------------------------------------------
-- COLOUR PALETTE  (mirrors game warm-dark theme)
--------------------------------------------------------
local C = {
    bg       = Color3.fromRGB(18,  20,  28),
    panel    = Color3.fromRGB(26,  29,  42),
    header   = Color3.fromRGB(34,  37,  55),
    accent   = Color3.fromRGB(255, 185,  50),   -- gold
    accent2  = Color3.fromRGB(255, 120,  30),   -- orange
    green    = Color3.fromRGB( 80, 210, 100),
    red      = Color3.fromRGB(220,  70,  70),
    text     = Color3.fromRGB(240, 240, 250),
    subtext  = Color3.fromRGB(160, 160, 180),
    stroke   = Color3.fromRGB( 70,  75, 110),
    dropdown = Color3.fromRGB( 30,  33,  50),
    optHover = Color3.fromRGB( 42,  46,  68),
}

--------------------------------------------------------
-- STATE
--------------------------------------------------------
local state = {
    stealActive  = false,
    espActive    = false,
    speedActive  = false,
    selectedPet  = nil,      -- { name, model, ridePrompt }
    status       = "idle",
    statusLabel  = nil,      -- assigned after UI build
    dropdownOpen = false,
    dropItems    = {},        -- list of TextButtons in dropdown
    stealThread  = nil,
    espConnections = {},
    espBillboards  = {},
    originalSpeed  = 16,
}

local DROP_HEIGHT    = 34
local SPEED_MULT     = 3.5
local STEAL_DELAY    = 0.6   -- seconds between teleport and prompt trigger
local LOOP_WAIT      = 0.4

--------------------------------------------------------
-- UTIL
--------------------------------------------------------
local function tween(obj, props, dur, style, dir)
    style = style or Enum.EasingStyle.Quad
    dir   = dir   or Enum.EasingDirection.Out
    return TweenService:Create(obj, TweenInfo.new(dur, style, dir), props):Play()
end

local function setStatus(msg, colour)
    state.status = msg
    if state.statusLabel then
        state.statusLabel.Text = msg
        state.statusLabel.TextColor3 = colour or C.subtext
    end
end

local function getHRP()
    local char = localPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
    local char = localPlayer.Character
    return char and char:FindFirstChildOfClass("Humanoid")
end

--------------------------------------------------------
-- GAME DATA QUERIES
--------------------------------------------------------
local function getOwnedPets()
    local pets   = {}
    local map    = workspace:FindFirstChild("Map")
    local bases  = map and map:FindFirstChild("Bases")
    if not bases then return pets end

    for _, base in ipairs(bases:GetChildren()) do
        local penPets = base:FindFirstChild("PenPets")
        if penPets then
            for _, pet in ipairs(penPets:GetChildren()) do
                if pet:GetAttribute("OwnerId") == localPlayer.UserId then
                    local hrp = pet:FindFirstChild("HumanoidRootPart")
                    table.insert(pets, {
                        name        = pet:GetAttribute("PetName") or pet.Name,
                        model       = pet,
                        ridePrompt  = hrp and hrp:FindFirstChild("RidePrompt") or nil,
                    })
                end
            end
        end
    end
    return pets
end

local function getNestEggs()
    local eggs  = {}
    local map   = workspace:FindFirstChild("Map")
    local biomes = map and map:FindFirstChild("Biomes")
    if not biomes then return eggs end

    for _, biome in ipairs(biomes:GetChildren()) do
        if biome.Name == "Barrier" then continue end
        local nests = biome:FindFirstChild("Nests")
        if nests then
            for _, nest in ipairs(nests:GetChildren()) do
                local egg = nest:FindFirstChild("Egg")
                if egg and egg:FindFirstChildOfClass("ProximityPrompt") then
                    table.insert(eggs, {
                        egg      = egg,
                        nest     = nest,
                        biome    = biome.Name,
                        eggName  = egg:GetAttribute("EggName") or "Egg",
                        position = egg.Position,
                    })
                end
            end
        end
    end

    local hrp = getHRP()
    if hrp then
        table.sort(eggs, function(a, b)
            return (a.position - hrp.Position).Magnitude
                 < (b.position - hrp.Position).Magnitude
        end)
    end
    return eggs
end

local function isRiding()
    local char = localPlayer.Character
    if not char then return false end
    local sp = char:FindFirstChild("ShownPet")
    return sp and sp:GetAttribute("Mode") == "Ride"
end

local function getOwnBase()
    local map   = workspace:FindFirstChild("Map")
    local bases = map and map:FindFirstChild("Bases")
    if not bases then return nil end
    for _, base in ipairs(bases:GetChildren()) do
        local penPets = base:FindFirstChild("PenPets")
        if penPets then
            for _, pet in ipairs(penPets:GetChildren()) do
                if pet:GetAttribute("OwnerId") == localPlayer.UserId then
                    local baseModel = base:FindFirstChild("Base")
                    if baseModel then
                        local root = baseModel:FindFirstChildWhichIsA("BasePart", true)
                        return root
                    end
                end
            end
        end
    end
    return nil
end

--------------------------------------------------------
-- STEAL SYSTEMS
--------------------------------------------------------
local function teleportNear(targetPos, offset)
    local hrp = getHRP()
    if not hrp then return end
    offset = offset or Vector3.new(0, 3, 4)
    hrp.CFrame = CFrame.new(targetPos + offset)
end

local function doRide()
    if not state.selectedPet then
        setStatus("เลือกสัตว์ก่อน", C.red) return
    end
    local prompt = state.selectedPet.ridePrompt
    if not prompt then
        -- try refresh
        local hrp = state.selectedPet.model:FindFirstChild("HumanoidRootPart")
        prompt = hrp and hrp:FindFirstChild("RidePrompt")
        state.selectedPet.ridePrompt = prompt
    end
    if not prompt then
        setStatus("ไม่พบ RidePrompt", C.red) return
    end
    -- teleport next to the pet first
    local petHRP = state.selectedPet.model:FindFirstChild("HumanoidRootPart")
    if petHRP then
        teleportNear(petHRP.Position, Vector3.new(0, 2, 3))
        task.wait(0.2)
    end
    prompt:Trigger()
    setStatus("ขึ้นขี่ " .. state.selectedPet.name, C.green)
end

local function stealLoop()
    while state.stealActive do
        local char = localPlayer.Character
        if not char then task.wait(1) continue end

        -- ensure riding first
        if not isRiding() then
            if not state.selectedPet then
                setStatus("เลือกสัตว์ก่อน", C.red)
                task.wait(1.5) continue
            end
            setStatus("กำลังขี่ " .. state.selectedPet.name .. "…", C.accent)
            doRide()
            task.wait(2)
            continue
        end

        -- find nearest nest egg
        local eggs = getNestEggs()
        if #eggs == 0 then
            setStatus("ไม่พบไข่ในแผนที่", C.red)
            task.wait(3) continue
        end

        local target = eggs[1]
        setStatus("→ " .. target.eggName .. " [" .. target.biome .. "]", C.accent)

        -- teleport near egg
        teleportNear(target.position, Vector3.new(0, 3, 5))
        task.wait(STEAL_DELAY)

        -- trigger ProximityPrompt
        local prompt = target.egg:FindFirstChildOfClass("ProximityPrompt")
        if prompt then
            prompt:Trigger()
            setStatus("ขโมย " .. target.eggName .. " ✓", C.green)
        else
            setStatus("ProximityPrompt หาย", C.red)
        end

        task.wait(LOOP_WAIT)
    end
    setStatus("หยุด steal", C.subtext)
end

local function toggleSteal(btn, indicator)
    state.stealActive = not state.stealActive
    if state.stealActive then
        btn.Label.Text = "Steal  ON"
        tween(indicator, {BackgroundColor3 = C.green}, 0.2)
        tween(btn, {BackgroundColor3 = Color3.fromRGB(30, 65, 35)}, 0.2)
        state.stealThread = task.spawn(stealLoop)
    else
        btn.Label.Text = "Steal  OFF"
        tween(indicator, {BackgroundColor3 = C.red}, 0.2)
        tween(btn, {BackgroundColor3 = C.panel}, 0.2)
        if state.stealThread then
            task.cancel(state.stealThread)
            state.stealThread = nil
        end
        setStatus("idle", C.subtext)
    end
end

--------------------------------------------------------
-- ESP SYSTEM
--------------------------------------------------------
local function clearESP()
    for _, bb in ipairs(state.espBillboards) do
        if bb and bb.Parent then bb:Destroy() end
    end
    state.espBillboards = {}
end

local function buildESP()
    clearESP()
    local map   = workspace:FindFirstChild("Map")
    local biomes = map and map:FindFirstChild("Biomes")
    if not biomes then return end

    for _, biome in ipairs(biomes:GetChildren()) do
        if biome.Name == "Barrier" then continue end
        local nests = biome:FindFirstChild("Nests")
        if nests then
            for _, nest in ipairs(nests:GetChildren()) do
                local egg = nest:FindFirstChild("Egg")
                if egg and egg:FindFirstChildOfClass("ProximityPrompt") then
                    local bb = Instance.new("BillboardGui")
                    bb.Name        = "SUNHUB_ESP"
                    bb.Size        = UDim2.new(0, 120, 0, 40)
                    bb.StudsOffset = Vector3.new(0, 4, 0)
                    bb.AlwaysOnTop = true
                    bb.Parent      = egg

                    local lbl = Instance.new("TextLabel", bb)
                    lbl.Size                = UDim2.fromScale(1, 1)
                    lbl.BackgroundColor3    = Color3.fromRGB(0, 0, 0)
                    lbl.BackgroundTransparency = 0.45
                    lbl.TextColor3          = C.accent
                    lbl.TextScaled          = true
                    lbl.Font                = Enum.Font.GothamBold
                    lbl.Text                = "🥚 " .. (egg:GetAttribute("EggName") or "Egg")
                    Instance.new("UICorner", lbl).CornerRadius = UDim.new(0, 6)

                    table.insert(state.espBillboards, bb)
                end
            end
        end
    end
end

local function toggleESP(btn, indicator)
    state.espActive = not state.espActive
    if state.espActive then
        btn.Label.Text = "ESP  ON"
        tween(indicator, {BackgroundColor3 = C.green}, 0.2)
        tween(btn, {BackgroundColor3 = Color3.fromRGB(30, 65, 35)}, 0.2)
        buildESP()
    else
        btn.Label.Text = "ESP  OFF"
        tween(indicator, {BackgroundColor3 = C.red}, 0.2)
        tween(btn, {BackgroundColor3 = C.panel}, 0.2)
        clearESP()
    end
end

--------------------------------------------------------
-- SPEED BOOST
--------------------------------------------------------
local function toggleSpeed(btn, indicator)
    state.speedActive = not state.speedActive
    local hum = getHumanoid()
    if state.speedActive then
        btn.Label.Text = "Speed  ON"
        tween(indicator, {BackgroundColor3 = C.green}, 0.2)
        tween(btn, {BackgroundColor3 = Color3.fromRGB(30, 65, 35)}, 0.2)
        if hum then
            state.originalSpeed = hum.WalkSpeed
            hum.WalkSpeed = state.originalSpeed * SPEED_MULT
        end
        -- keep applying on respawn
        state.speedConn = localPlayer.CharacterAdded:Connect(function(char)
            local h = char:WaitForChild("Humanoid")
            task.wait(0.1)
            if state.speedActive then
                h.WalkSpeed = state.originalSpeed * SPEED_MULT
            end
        end)
    else
        btn.Label.Text = "Speed  OFF"
        tween(indicator, {BackgroundColor3 = C.red}, 0.2)
        tween(btn, {BackgroundColor3 = C.panel}, 0.2)
        if hum then hum.WalkSpeed = state.originalSpeed end
        if state.speedConn then state.speedConn:Disconnect() end
    end
end

--------------------------------------------------------
-- UI BUILDER HELPERS
--------------------------------------------------------
local function mk(cls, props, parent)
    local obj = Instance.new(cls)
    for k, v in pairs(props) do obj[k] = v end
    if parent then obj.Parent = parent end
    return obj
end

local function corner(r, parent)
    return mk("UICorner", {CornerRadius = UDim.new(0, r)}, parent)
end

local function stroke(thickness, colour, parent)
    return mk("UIStroke", {
        Thickness = thickness,
        Color     = colour or C.stroke,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, parent)
end

local function grad(colours, rotation, parent)
    -- colours: {{Color, Time}, …}
    local g = mk("UIGradient", {Rotation = rotation or 90}, parent)
    local seq = {}
    for _, c in ipairs(colours) do
        table.insert(seq, ColorSequenceKeypoint.new(c[2], c[1]))
    end
    g.Color = ColorSequence.new(seq)
    return g
end

local function label(text, size, colour, font, parent)
    local l = mk("TextLabel", {
        Size                = size,
        Text                = text,
        TextColor3          = colour or C.text,
        TextScaled          = true,
        Font                = font or Enum.Font.GothamBold,
        BackgroundTransparency = 1,
    }, parent)
    mk("UITextSizeConstraint", {MaxTextSize = 20}, l)
    return l
end

local function iconLabel(img, size, parent)
    return mk("ImageLabel", {
        Size  = size,
        Image = img,
        BackgroundTransparency = 1,
        ScaleType = Enum.ScaleType.Fit,
    }, parent)
end

-- toggle button matching game style: UICorner, UIStroke, UIGradient, Label, indicator dot
local function makeToggleBtn(parent, text, yPos)
    local btn = mk("Frame", {
        Name               = "ToggleBtn",
        Size               = UDim2.new(1, -16, 0, 36),
        Position           = UDim2.new(0, 8, 0, yPos),
        BackgroundColor3   = C.panel,
        BorderSizePixel    = 0,
    }, parent)
    corner(8, btn)
    stroke(1.2, C.stroke, btn)

    -- left indicator dot
    local dot = mk("Frame", {
        Name             = "Indicator",
        Size             = UDim2.new(0, 10, 0, 10),
        Position         = UDim2.new(0, 10, 0.5, -5),
        BackgroundColor3 = C.red,
        BorderSizePixel  = 0,
    }, btn)
    corner(5, dot)

    -- clickable label
    local lbl = mk("TextButton", {
        Name                   = "Label",
        Size                   = UDim2.new(1, -30, 1, 0),
        Position               = UDim2.new(0, 26, 0, 0),
        BackgroundTransparency = 1,
        Text                   = text .. "  OFF",
        TextColor3             = C.text,
        TextScaled             = true,
        Font                   = Enum.Font.GothamSemibold,
        TextXAlignment         = Enum.TextXAlignment.Left,
    }, btn)
    mk("UITextSizeConstraint", {MaxTextSize = 16}, lbl)

    return btn, lbl, dot
end

-- action button (Ride, Refresh)
local function makeActionBtn(parent, text, yPos, accent)
    local btn = mk("TextButton", {
        Name               = "ActionBtn",
        Size               = UDim2.new(1, -16, 0, 34),
        Position           = UDim2.new(0, 8, 0, yPos),
        BackgroundColor3   = accent or C.accent,
        BorderSizePixel    = 0,
        Text               = "",
    }, parent)
    corner(8, btn)
    stroke(1.2, Color3.fromRGB(200, 150, 30), btn)
    grad({
        {Color3.fromRGB(255, 200,  60), 0},
        {Color3.fromRGB(220, 130,  20), 1},
    }, 90, btn)

    local lbl = mk("TextLabel", {
        Name               = "Label",
        Size               = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text               = text,
        TextColor3         = Color3.fromRGB(30, 20, 5),
        Font               = Enum.Font.GothamBold,
        TextScaled         = true,
    }, btn)
    mk("UITextSizeConstraint", {MaxTextSize = 17}, lbl)

    -- hover
    btn.MouseEnter:Connect(function()
        tween(btn, {BackgroundColor3 = Color3.fromRGB(255, 210, 80)}, 0.15)
    end)
    btn.MouseLeave:Connect(function()
        tween(btn, {BackgroundColor3 = accent or C.accent}, 0.15)
    end)

    return btn
end

-- section header
local function sectionHeader(parent, text, yPos)
    local hdr = mk("TextLabel", {
        Size                = UDim2.new(1, -16, 0, 20),
        Position            = UDim2.new(0, 8, 0, yPos),
        BackgroundTransparency = 1,
        Text                = text,
        TextColor3          = C.accent,
        Font                = Enum.Font.GothamBlack,
        TextScaled          = true,
        TextXAlignment      = Enum.TextXAlignment.Left,
    }, parent)
    mk("UITextSizeConstraint", {MaxTextSize = 13}, hdr)
    return hdr
end

-- divider line
local function divider(parent, yPos)
    return mk("Frame", {
        Size             = UDim2.new(1, -16, 0, 1),
        Position         = UDim2.new(0, 8, 0, yPos),
        BackgroundColor3 = C.stroke,
        BorderSizePixel  = 0,
    }, parent)
end

--------------------------------------------------------
-- DROPDOWN  (mirrors game Settings.VFX dropdown style)
--------------------------------------------------------
local function buildDropdown(parent, yPos, listHolder)
    --[[ 
        Structure: outer Frame > Dropdown TextButton (Label + Arrow icon + UICorner + UIStroke + UIGradient)
        Below: dropMenu Frame (clipped, list of Option TextButtons)
        Mirrors: StarterGui.GameUI.Windows.Settings.Body.VFX.Dropdown
    ]]

    local outer = mk("Frame", {
        Name             = "PetDropdownOuter",
        Size             = UDim2.new(1, -16, 0, 34),
        Position         = UDim2.new(0, 8, 0, yPos),
        BackgroundTransparency = 1,
        ClipsDescendants = false,
        ZIndex           = 5,
    }, parent)

    local dropBtn = mk("TextButton", {
        Name             = "Dropdown",
        Size             = UDim2.fromScale(1, 1),
        BackgroundColor3 = C.dropdown,
        BorderSizePixel  = 0,
        Text             = "",
        ZIndex           = 5,
    }, outer)
    corner(8, dropBtn)
    stroke(1.2, C.stroke, dropBtn)
    grad({
        {Color3.fromRGB(38, 42, 62), 0},
        {Color3.fromRGB(24, 27, 42), 1},
    }, 90, dropBtn)

    local lbl = mk("TextLabel", {
        Name               = "Label",
        Size               = UDim2.new(1, -36, 1, 0),
        Position           = UDim2.new(0, 10, 0, 0),
        BackgroundTransparency = 1,
        Text               = "— เลือกสัตว์ —",
        TextColor3         = C.subtext,
        Font               = Enum.Font.GothamSemibold,
        TextScaled         = true,
        TextXAlignment     = Enum.TextXAlignment.Left,
        ZIndex             = 6,
    }, dropBtn)
    mk("UITextSizeConstraint", {MaxTextSize = 15}, lbl)

    local arrow = mk("ImageLabel", {
        Name               = "Arrow",
        Size               = UDim2.new(0, 16, 0, 16),
        Position           = UDim2.new(1, -24, 0.5, -8),
        BackgroundTransparency = 1,
        -- Roblox native arrow icon (dropdown chevron)
        Image              = "rbxassetid://6034818372",
        Rotation           = 0,
        ZIndex             = 6,
    }, dropBtn)

    -- drop menu (appears below the button)
    local dropMenu = mk("Frame", {
        Name             = "DropMenu",
        Size             = UDim2.new(1, 0, 0, 0),
        Position         = UDim2.new(0, 0, 1, 4),
        BackgroundColor3 = C.dropdown,
        ClipsDescendants = true,
        Visible          = false,
        ZIndex           = 10,
    }, outer)
    corner(8, dropMenu)
    stroke(1.2, C.stroke, dropMenu)

    local scroll = mk("ScrollingFrame", {
        Name             = "List",
        Size             = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = C.accent,
        CanvasSize       = UDim2.fromScale(0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ZIndex           = 10,
    }, dropMenu)
    mk("UIListLayout", {
        SortOrder        = Enum.SortOrder.LayoutOrder,
        Padding          = UDim.new(0, 3),
    }, scroll)
    mk("UIPadding", {
        PaddingTop       = UDim.new(0, 4),
        PaddingBottom    = UDim.new(0, 4),
        PaddingLeft      = UDim.new(0, 4),
        PaddingRight     = UDim.new(0, 4),
    }, scroll)

    local menuOpen = false

    local function setMenuOpen(open)
        menuOpen = open
        state.dropdownOpen = open
        dropMenu.Visible = open
        if open then
            tween(dropMenu, {Size = UDim2.new(1, 0, 0, math.min(#state.dropItems * (DROP_HEIGHT+3) + 8, 180))}, 0.2)
            tween(arrow, {Rotation = 180}, 0.2)
        else
            tween(dropMenu, {Size = UDim2.new(1, 0, 0, 0)}, 0.15)
            tween(arrow, {Rotation = 0}, 0.15)
            task.delay(0.16, function() if not menuOpen then dropMenu.Visible = false end end)
        end
    end

    dropBtn.MouseButton1Click:Connect(function()
        setMenuOpen(not menuOpen)
    end)

    -- populate function
    local function refreshPetList(selectedCallback)
        -- clear old
        for _, opt in ipairs(state.dropItems) do
            if opt and opt.Parent then opt:Destroy() end
        end
        state.dropItems = {}

        local pets = getOwnedPets()
        if #pets == 0 then
            lbl.Text = "ไม่พบสัตว์ที่เป็นเจ้าของ"
            lbl.TextColor3 = C.red
            return
        end

        for i, pet in ipairs(pets) do
            local opt = mk("TextButton", {
                Name             = "Opt_" .. pet.name,
                Size             = UDim2.new(1, 0, 0, DROP_HEIGHT),
                BackgroundColor3 = C.panel,
                BorderSizePixel  = 0,
                Text             = "",
                LayoutOrder      = i,
                ZIndex           = 11,
            }, scroll)
            corner(6, opt)

            local optIcon = mk("ImageLabel", {
                Size               = UDim2.new(0, 22, 0, 22),
                Position           = UDim2.new(0, 6, 0.5, -11),
                BackgroundTransparency = 1,
                Image              = ICO.pets,
                ZIndex             = 12,
            }, opt)

            local optLbl = mk("TextLabel", {
                Size               = UDim2.new(1, -36, 1, 0),
                Position           = UDim2.new(0, 32, 0, 0),
                BackgroundTransparency = 1,
                Text               = pet.name,
                TextColor3         = C.text,
                Font               = Enum.Font.GothamSemibold,
                TextScaled         = true,
                TextXAlignment     = Enum.TextXAlignment.Left,
                ZIndex             = 12,
            }, opt)
            mk("UITextSizeConstraint", {MaxTextSize = 14}, optLbl)

            opt.MouseEnter:Connect(function()
                tween(opt, {BackgroundColor3 = C.optHover}, 0.1)
            end)
            opt.MouseLeave:Connect(function()
                tween(opt, {BackgroundColor3 = C.panel}, 0.1)
            end)

            opt.MouseButton1Click:Connect(function()
                state.selectedPet = pet
                lbl.Text       = pet.name
                lbl.TextColor3 = C.accent
                setMenuOpen(false)
                selectedCallback(pet)
            end)

            table.insert(state.dropItems, opt)
        end
    end

    return outer, dropMenu, refreshPetList
end

--------------------------------------------------------
-- MAIN HUB WINDOW
--------------------------------------------------------
local function buildHub()
    -- destroy old hub if it exists
    local old = playerGui:FindFirstChild("SunHub")
    if old then old:Destroy() end

    local sg = mk("ScreenGui", {
        Name             = "SunHub",
        ResetOnSpawn     = false,
        ZIndexBehavior   = Enum.ZIndexBehavior.Sibling,
    }, playerGui)

    -- main window
    local win = mk("Frame", {
        Name             = "Window",
        Size             = UDim2.new(0, 310, 0, 440),
        Position         = UDim2.new(0.03, 0, 0.08, 0),
        BackgroundColor3 = C.bg,
        BorderSizePixel  = 0,
        Active           = true,
    }, sg)
    corner(12, win)
    stroke(1.5, C.stroke, win)

    -------------------------------------------------------
    -- HEADER
    -------------------------------------------------------
    local hdr = mk("Frame", {
        Name             = "Header",
        Size             = UDim2.new(1, 0, 0, 46),
        BackgroundColor3 = C.header,
        BorderSizePixel  = 0,
    }, win)
    corner(12, hdr)
    -- cover bottom corners
    mk("Frame", {
        Size             = UDim2.new(1, 0, 0.5, 0),
        Position         = UDim2.new(0, 0, 0.5, 0),
        BackgroundColor3 = C.header,
        BorderSizePixel  = 0,
    }, hdr)
    grad({
        {Color3.fromRGB(50, 55, 80), 0},
        {Color3.fromRGB(28, 32, 52), 1},
    }, 90, hdr)
    stroke(1.5, C.stroke, hdr)

    -- icon in header (from game's Pets button icon)
    local hdrIcon = mk("ImageLabel", {
        Size               = UDim2.new(0, 28, 0, 28),
        Position           = UDim2.new(0, 10, 0.5, -14),
        BackgroundTransparency = 1,
        Image              = ICO.pets,
    }, hdr)

    local hdrTitle = mk("TextLabel", {
        Size               = UDim2.new(1, -90, 1, 0),
        Position           = UDim2.new(0, 44, 0, 0),
        BackgroundTransparency = 1,
        Text               = "SunHub",
        TextColor3         = C.accent,
        Font               = Enum.Font.GothamBlack,
        TextScaled         = true,
        TextXAlignment     = Enum.TextXAlignment.Left,
    }, hdr)
    mk("UITextSizeConstraint", {MaxTextSize = 22}, hdrTitle)

    local hdrSub = mk("TextLabel", {
        Size               = UDim2.new(1, -90, 0, 14),
        Position           = UDim2.new(0, 44, 1, -16),
        BackgroundTransparency = 1,
        Text               = "Ride & Steal Eggs",
        TextColor3         = C.subtext,
        Font               = Enum.Font.Gotham,
        TextScaled         = true,
        TextXAlignment     = Enum.TextXAlignment.Left,
    }, hdr)
    mk("UITextSizeConstraint", {MaxTextSize = 12}, hdrSub)

    -- close button  (mirrors game's Header.Close style)
    local closeBtn = mk("TextButton", {
        Name             = "Close",
        Size             = UDim2.new(0, 28, 0, 28),
        Position         = UDim2.new(1, -36, 0.5, -14),
        BackgroundColor3 = Color3.fromRGB(190, 50, 50),
        BorderSizePixel  = 0,
        Text             = "×",
        TextColor3       = Color3.fromRGB(255, 255, 255),
        Font             = Enum.Font.GothamBold,
        TextScaled       = true,
    }, hdr)
    corner(6, closeBtn)
    stroke(1, Color3.fromRGB(220, 80, 80), closeBtn)
    mk("UITextSizeConstraint", {MaxTextSize = 20}, closeBtn)

    closeBtn.MouseButton1Click:Connect(function()
        tween(win, {Size = UDim2.new(0, 310, 0, 0), Position = win.Position + UDim2.new(0, 0, 0, 20)}, 0.2)
        task.delay(0.22, function() sg:Destroy() end)
    end)

    -------------------------------------------------------
    -- BODY  (scrollable)
    -------------------------------------------------------
    local body = mk("ScrollingFrame", {
        Name             = "Body",
        Size             = UDim2.new(1, 0, 1, -46),
        Position         = UDim2.new(0, 0, 0, 46),
        BackgroundTransparency = 1,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = C.accent,
        CanvasSize       = UDim2.fromScale(0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ClipsDescendants = true,
    }, win)

    local y = 8  -- running Y offset inside body

    -------------------------------------------------------
    -- STATUS BAR
    -------------------------------------------------------
    local statusBar = mk("Frame", {
        Size             = UDim2.new(1, -16, 0, 28),
        Position         = UDim2.new(0, 8, 0, y),
        BackgroundColor3 = Color3.fromRGB(22, 25, 38),
        BorderSizePixel  = 0,
    }, body)
    corner(6, statusBar)
    stroke(1, C.stroke, statusBar)

    local statusDot = mk("Frame", {
        Size             = UDim2.new(0, 8, 0, 8),
        Position         = UDim2.new(0, 8, 0.5, -4),
        BackgroundColor3 = C.subtext,
        BorderSizePixel  = 0,
    }, statusBar)
    corner(4, statusDot)

    local statusLbl = mk("TextLabel", {
        Size               = UDim2.new(1, -26, 1, 0),
        Position           = UDim2.new(0, 22, 0, 0),
        BackgroundTransparency = 1,
        Text               = "idle",
        TextColor3         = C.subtext,
        Font               = Enum.Font.Gotham,
        TextScaled         = true,
        TextXAlignment     = Enum.TextXAlignment.Left,
    }, statusBar)
    mk("UITextSizeConstraint", {MaxTextSize = 14}, statusLbl)

    state.statusLabel = statusLbl
    -- keep dot colour in sync
    task.spawn(function()
        while sg.Parent do
            local col = state.stealActive and C.green or C.subtext
            statusDot.BackgroundColor3 = col
            task.wait(0.5)
        end
    end)

    y = y + 36

    -------------------------------------------------------
    -- SECTION: MOUNT
    -------------------------------------------------------
    divider(body, y) y = y + 8
    sectionHeader(body, "  สัตว์ที่จะขี่", y) y = y + 24

    -- dropdown
    local dropOuter, dropMenu, refreshPetList = buildDropdown(body, y, sg)
    y = y + 38

    -- Ride + Refresh row
    local rideBtn    = makeActionBtn(body, "Ride — ขึ้นขี่", y, C.accent)
    rideBtn.Size = UDim2.new(0.54, -20, 0, 34)
    rideBtn.Position = UDim2.new(0, 8, 0, y)
    y_after_ride = y  -- used below for refresh

    local refreshBtn = mk("TextButton", {
        Name             = "RefreshBtn",
        Size             = UDim2.new(0.44, -4, 0, 34),
        Position         = UDim2.new(0.56, 0, 0, y),
        BackgroundColor3 = C.panel,
        BorderSizePixel  = 0,
        Text             = "",
    }, body)
    corner(8, refreshBtn)
    stroke(1.2, C.stroke, refreshBtn)
    local refreshLbl = mk("TextLabel", {
        Size               = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text               = "↺ รีเฟรช",
        TextColor3         = C.subtext,
        Font               = Enum.Font.GothamSemibold,
        TextScaled         = true,
    }, refreshBtn)
    mk("UITextSizeConstraint", {MaxTextSize = 14}, refreshLbl)

    y = y + 42

    rideBtn.MouseButton1Click:Connect(doRide)

    refreshBtn.MouseButton1Click:Connect(function()
        refreshPetList(function(pet)
            setStatus("เลือก " .. pet.name, C.accent)
        end)
        setStatus("รีเฟรชรายการสัตว์แล้ว", C.subtext)
    end)

    -- initial populate
    refreshPetList(function(pet)
        setStatus("เลือก " .. pet.name, C.accent)
    end)

    -------------------------------------------------------
    -- SECTION: STEAL
    -------------------------------------------------------
    divider(body, y) y = y + 8
    sectionHeader(body, "  ขโมยไข่", y) y = y + 24

    local _, stealLbl, stealDot = makeToggleBtn(body, "Steal", y)
    local stealFrame = body:FindFirstChild("ToggleBtn") -- last one added
    -- rename to avoid collision
    stealFrame.Name = "StealToggle"
    y = y + 42

    stealLbl.MouseButton1Click:Connect(function()
        toggleSteal(stealFrame, stealDot)
    end)

    -------------------------------------------------------
    -- SECTION: TOOLS
    -------------------------------------------------------
    divider(body, y) y = y + 8
    sectionHeader(body, "  เครื่องมือ", y) y = y + 24

    -- ESP toggle
    local _, espLbl, espDot = makeToggleBtn(body, "ESP", y)
    local espFrame = body:FindFirstChild("ToggleBtn")
    espFrame.Name = "EspToggle"
    y = y + 42

    espLbl.MouseButton1Click:Connect(function()
        toggleESP(espFrame, espDot)
    end)

    -- Speed toggle
    local _, speedLbl, speedDot = makeToggleBtn(body, "Speed", y)
    local speedFrame = body:FindFirstChild("ToggleBtn")
    speedFrame.Name = "SpeedToggle"
    y = y + 42

    speedLbl.MouseButton1Click:Connect(function()
        toggleSpeed(speedFrame, speedDot)
    end)

    -------------------------------------------------------
    -- SECTION: INFO
    -------------------------------------------------------
    divider(body, y) y = y + 8
    sectionHeader(body, "  ข้อมูลสนาม", y) y = y + 24

    local infoFrame = mk("Frame", {
        Size             = UDim2.new(1, -16, 0, 56),
        Position         = UDim2.new(0, 8, 0, y),
        BackgroundColor3 = C.panel,
        BorderSizePixel  = 0,
    }, body)
    corner(8, infoFrame)
    stroke(1, C.stroke, infoFrame)

    local nestCountLbl = mk("TextLabel", {
        Size               = UDim2.new(1, -12, 0, 26),
        Position           = UDim2.new(0, 8, 0, 2),
        BackgroundTransparency = 1,
        Text               = "ไข่ในแผนที่: กำลังโหลด…",
        TextColor3         = C.text,
        Font               = Enum.Font.Gotham,
        TextScaled         = true,
        TextXAlignment     = Enum.TextXAlignment.Left,
    }, infoFrame)
    mk("UITextSizeConstraint", {MaxTextSize = 14}, nestCountLbl)

    local rideStatusLbl = mk("TextLabel", {
        Size               = UDim2.new(1, -12, 0, 22),
        Position           = UDim2.new(0, 8, 0, 30),
        BackgroundTransparency = 1,
        Text               = "สถานะ: ไม่ได้ขี่",
        TextColor3         = C.subtext,
        Font               = Enum.Font.Gotham,
        TextScaled         = true,
        TextXAlignment     = Enum.TextXAlignment.Left,
    }, infoFrame)
    mk("UITextSizeConstraint", {MaxTextSize = 13}, rideStatusLbl)

    y = y + 64

    -- live update info panel
    task.spawn(function()
        while sg.Parent do
            local eggs = getNestEggs()
            nestCountLbl.Text = "ไข่ในแผนที่: " .. #eggs .. " รัง"
            rideStatusLbl.Text = isRiding()
                and "สถานะ: กำลังขี่ " .. (localPlayer.Character and localPlayer.Character:FindFirstChild("ShownPet") and localPlayer.Character.ShownPet:GetAttribute("PetName") or "?")
                or  "สถานะ: เดินเท้า"
            rideStatusLbl.TextColor3 = isRiding() and C.green or C.subtext
            task.wait(1)
        end
    end)

    -------------------------------------------------------
    -- DRAG SUPPORT
    -------------------------------------------------------
    local dragging, dragInput, dragStart, startPos

    hdr.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging  = true
            dragStart = inp.Position
            startPos  = win.Position
            inp.Changed:Connect(function()
                if inp.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    hdr.InputChanged:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseMovement then
            dragInput = inp
        end
    end)

    UserInputService.InputChanged:Connect(function(inp)
        if dragging and inp == dragInput then
            local delta = inp.Position - dragStart
            win.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)

    -------------------------------------------------------
    -- INTRO ANIMATION
    -------------------------------------------------------
    win.Size = UDim2.new(0, 310, 0, 0)
    tween(win, {Size = UDim2.new(0, 310, 0, 440)}, 0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

    return sg
end

--------------------------------------------------------
-- ENTRY POINT
--------------------------------------------------------
local hub = buildHub()

-- keybind: RightControl toggles hub visibility
UserInputService.InputBegan:Connect(function(inp, processed)
    if processed then return end
    if inp.KeyCode == Enum.KeyCode.RightControl then
        local win = hub and hub:FindFirstChild("Window")
        if win then
            win.Visible = not win.Visible
        end
    end
end)

setStatus("SunHub โหลดแล้ว — RCtrl ซ่อน/แสดง", C.accent)

--[[
    SUNHUB — Ride & Steal Eggs  (PlaceId 15448459363)
    ────────────────────────────────────────────────────
    SYSTEMS
      • Pet Dropdown   — สแกน PenPets ทุก Base ที่ OwnerId == ผู้เล่น
                         เลือกสัตว์แล้วกด "Ride" หรือเปิด Steal (mount อัตโนมัติ)
      • Auto-Steal     — ขี่สัตว์ → scan Biome Nests → teleport → ProximityPrompt:Trigger()
      • ESP            — BillboardGui บนทุกไข่ในแผนที่
      • Speed Boost    — คูณ WalkSpeed ×3.5 ขณะขี่
      • Info Panel     — นับไข่, แสดง Ride state แบบ real-time
    PATHS USED
      Workspace.Map.Bases.*.PenPets.*         → สัตว์ + RidePrompt
      Workspace.Map.Biomes.*.Nests.*.Egg      → ไข่ + ProximityPrompt
      Workspace.Character.*.ShownPet          → ตรวจสถานะขี่
    KEYBIND
      RightControl — ซ่อน/แสดง hub
]]
