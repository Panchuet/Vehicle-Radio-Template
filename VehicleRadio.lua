behaviour("VehicleRadio")

function VehicleRadio:Start()
    self.radioPrefabTemplate = self.targets.radioPrefab.gameObject

    -- Radio settings
    self.playerRadio2d = self.script.mutator.GetConfigurationBool("playerRadio2d")
    self.playerAutoPlay = self.script.mutator.GetConfigurationBool("playerAutoPlay")
    self.playerRadioStaysOn = self.script.mutator.GetConfigurationBool("playerRadioStaysOn")
    self.botRadioStaysOn = self.script.mutator.GetConfigurationBool("botRadioStaysOn")

    -- Keybinds
    self.radioToggle = string.lower(self.script.mutator.GetConfigurationString("radioToggle"))
    self.volUpKey = string.lower(self.script.mutator.GetConfigurationString("volUpKey"))
    self.volDownKey = string.lower(self.script.mutator.GetConfigurationString("volDownKey"))
    self.skipKey = string.lower(self.script.mutator.GetConfigurationString("skipKey"))

    -- Bot / gameplay settings
    self.botPlayChance = self.script.mutator.GetConfigurationRange("botPlayChance")

    -- Team selection
    self.teamSelection = self.script.mutator.GetConfigurationDropdown("team")
    if self.teamSelection == 1 then
        self.allowedTeam = Team.Blue
    elseif self.teamSelection == 2 then
        self.allowedTeam = Team.Red
    else
        self.allowedTeam = nil
    end

    self.vehicleRadios = {} 

    GameEvents.onVehicleSpawn.AddListener(self, "OnVehicleSpawn")
    GameEvents.onVehicleDestroyed.AddListener(self, "OnVehicleDestroyed")
    
    self:InitialVehiclesFix()
    
    self.script.StartCoroutine(function() self:AutoPlayRoutine() end)
end

function VehicleRadio:InitialVehiclesFix()
    self.script.StartCoroutine(function()
        coroutine.yield(WaitForSeconds(0.1))
        for _, vehicle in pairs(ActorManager.vehicles) do
            self:OnVehicleSpawn(vehicle)
        end
    end)
end

function VehicleRadio:OnVehicleSpawn(vehicle)
    if not vehicle then return end
    
    if vehicle.isTurret then 
        return 
    end 
    
    if self:GetRadioByGameObjectMatch(vehicle) then 
        return 
    end 

    local attachTransform = vehicle.transform
    for i, seat in ipairs(vehicle.seats) do
        if seat.isDriverSeat then
            attachTransform = seat.transform
            break
        end
    end

    local newRadioObj = GameObject.Instantiate(self.radioPrefabTemplate)
    newRadioObj.transform.parent = attachTransform
    newRadioObj.transform.localPosition = Vector3.zero

    local soundBank = newRadioObj:GetComponent(SoundBank)
    local audioSource = newRadioObj:GetComponent(AudioSource)

    if audioSource then
        if self.playerRadio2d and Player.actor and vehicle == Player.actor.activeVehicle then
            audioSource.spatialBlend = 0.0
        else
            audioSource.spatialBlend = 1.0
        end
    end

    newRadioObj:SetActive(true)

    local radioData = {
        vehicle = vehicle,
        name = vehicle.name,
        radioObj = newRadioObj,        
        soundBank = soundBank,
        audioSource = audioSource,
        isOn = false,            
        volume = 1.0,
        manuallyTurnedOff = false,      
        availableTracks = {},
        trackCount = 0,
        seatOccupants = {},
        playerExitBuffer = false
    }

    if soundBank and soundBank.clips then
        radioData.trackCount = #soundBank.clips
    else
        print("<color=red>[ERROR] Radio attached to " .. vehicle.name .. " but no SoundBank or clips were found!</color>")
    end

    self.vehicleRadios[vehicle] = radioData
    self:PopulateTracks(radioData)

    if vehicle.seats then
        for i, seat in ipairs(vehicle.seats) do
            self.script.AddValueMonitor("MonitorSeatOccupant", "OnSeatOccupantChanged", seat)
        end
    end
end

function VehicleRadio:OnVehicleDestroyed(vehicle)
    local radio, actualVehicleKey = self:GetRadioByGameObjectMatch(vehicle)
    
    if radio and actualVehicleKey then
        if radio.radioObj then GameObject.Destroy(radio.radioObj) end
        self.vehicleRadios[actualVehicleKey] = nil
    end
end

function VehicleRadio:MonitorSeatOccupant()
    local seat = CurrentEvent.listenerData
    if seat then
        return seat.occupant
    end
    return nil
end

function VehicleRadio:OnSeatOccupantChanged()
    local seat = CurrentEvent.listenerData
    if not seat or not seat.vehicle then return end

    local radio = self:GetRadioByGameObjectMatch(seat.vehicle)
    if not radio then return end

    local newOccupant = seat.occupant
    local oldOccupant = radio.seatOccupants[seat]
    
    local wasEmpty = (self:GetOccupantCount(radio) == 0)

    radio.seatOccupants[seat] = newOccupant

    if newOccupant then
        self:ProcessSeatEntry(radio, seat, newOccupant, wasEmpty)
        
    elseif oldOccupant then
        self:ProcessSeatExit(radio, seat, oldOccupant)
    end
end

function VehicleRadio:ProcessSeatEntry(radio, seat, occupant, wasEmpty)
    if self.allowedTeam ~= nil and occupant.team ~= self.allowedTeam then
        return
    end

    if occupant.isPlayer then
        if self.playerRadio2d and radio.audioSource then
            radio.audioSource.spatialBlend = 0.0
        end

        if self.playerAutoPlay and not radio.isOn and not radio.manuallyTurnedOff then
            radio.isOn = true
            if not self:IsAudioPlaying(radio) then
                self:PlayNextTrack(radio)
            end
        end

    elseif occupant.isBot then
        if wasEmpty and not radio.isOn and not radio.manuallyTurnedOff then
            local roll = math.random(1, 100)
            if roll <= self.botPlayChance then
                radio.isOn = true
                if not self:IsAudioPlaying(radio) then
                    self:PlayNextTrack(radio)
                end
            end
        end
    end
end

function VehicleRadio:ProcessSeatExit(radio, seat, oldOccupant)
    if oldOccupant.isPlayer then
        if radio.audioSource then
            radio.audioSource.spatialBlend = 1.0
        end

        radio.playerExitBuffer = true 
        
        self.script.StartCoroutine(function()
            coroutine.yield(WaitForSeconds(0.1))
            if radio then 
                radio.playerExitBuffer = false 
                
                if not self.playerRadioStaysOn and self:GetOccupantCount(radio) == 0 and radio.isOn then
                    radio.isOn = false
                    radio.manuallyTurnedOff = false
                    self:StopCurrentAudio(radio)
                end
            end
        end)
        
    elseif oldOccupant.isBot then
        if not self.botRadioStaysOn and self:GetOccupantCount(radio) == 0 and radio.isOn and not radio.playerExitBuffer then
            radio.isOn = false
            radio.manuallyTurnedOff = false
            self:StopCurrentAudio(radio)
        end
    end
end

function VehicleRadio:AutoPlayRoutine()
    while true do
        coroutine.yield(WaitForSeconds(1.0))
        for vehicle, radio in pairs(self.vehicleRadios) do
            if radio.isOn and not self:IsAudioPlaying(radio) then
                self:PlayNextTrack(radio)
            end
        end
    end
end

function VehicleRadio:Update()
    if Player.actor and Player.actor.isSeated then
        
        if self.allowedTeam ~= nil and Player.actor.team ~= self.allowedTeam then
            return
        end

        local currentVehicle = Player.actor.activeVehicle
        local radio = self:GetRadioByGameObjectMatch(currentVehicle)
        
        if radio then
            if Input.GetKeyDown(self.radioToggle) then
                radio.isOn = not radio.isOn
                radio.manuallyTurnedOff = not radio.isOn 
                
                print("<color=blue>[INPUT] Toggle Radio -> " .. (radio.isOn and "ON" or "OFF") .. " in " .. radio.name .. "</color>")
                if not radio.isOn then 
                    self:StopCurrentAudio(radio) 
                else
                    if not self:IsAudioPlaying(radio) then
                        self:PlayNextTrack(radio)
                    end
                end
            end

            if radio.isOn then
                if Input.GetKeyDown(self.skipKey) then
                    print("<color=blue>[INPUT] Skip Song pressed in " .. radio.name .. "</color>")
                    self:PlayNextTrack(radio)
                end

                if Input.GetKeyDown(self.volUpKey) then
                    radio.volume = math.min(radio.volume + 0.1, 1.0)
                    print(string.format("<color=orange>[INPUT] Volume UP -> %.1f in %s</color>", radio.volume, radio.name))
                    self:UpdateVolume(radio)
                end

                if Input.GetKeyDown(self.volDownKey) then
                    radio.volume = math.max(radio.volume - 0.1, 0.0)
                    print(string.format("<color=orange>[INPUT] Volume DOWN -> %.1f in %s</color>", radio.volume, radio.name))
                    self:UpdateVolume(radio)
                end
            end
        end
    end
end

function VehicleRadio:GetOccupantCount(radio)
    local count = 0
    if not radio.seatOccupants then return 0 end
    for _, occ in pairs(radio.seatOccupants) do
        if occ ~= nil then
            count = count + 1
        end
    end
    return count
end

function VehicleRadio:GetRadioByGameObjectMatch(targetVehicle)
    if not targetVehicle then return nil, nil end
    
    for vehicleKey, radioData in pairs(self.vehicleRadios) do
        if vehicleKey.gameObject == targetVehicle.gameObject then
            return radioData, vehicleKey
        end
    end
    
    return nil, nil
end

function VehicleRadio:IsAudioPlaying(radio)
    if radio.audioSource then 
        return radio.audioSource.isPlaying 
    end
    return false
end

function VehicleRadio:UpdateVolume(radio)
    if radio.audioSource then 
        radio.audioSource.volume = radio.volume 
    end
end

function VehicleRadio:StopCurrentAudio(radio)
    if radio.audioSource then 
        radio.audioSource:Stop()
    end
end

function VehicleRadio:PopulateTracks(radio)
    radio.availableTracks = {}
    for i = 0, radio.trackCount - 1 do
        table.insert(radio.availableTracks, i)
    end
end

function VehicleRadio:PlayNextTrack(radio)
    self:StopCurrentAudio(radio)
    
    if #radio.availableTracks == 0 then
        self:PopulateTracks(radio)
    end
    
    if #radio.availableTracks > 0 then
        local randomTableIndex = math.random(1, #radio.availableTracks)
        local nextTrackIndex = radio.availableTracks[randomTableIndex]
        
        table.remove(radio.availableTracks, randomTableIndex)
        print("<color=cyan>[AUDIO] Now Playing Track Index [" .. nextTrackIndex .. "] on " .. radio.name .. "</color>")
        
        if radio.soundBank then
            radio.soundBank:PlaySoundBank(nextTrackIndex)
        else
            print("<color=red>[ERROR] SoundBank missing when trying to play track on " .. radio.name .. "</color>")
        end
        self:UpdateVolume(radio)
    else
        print("<color=red>[ERROR] No tracks available to play on " .. radio.name .. " even after attempted repopulation.</color>")
    end
end