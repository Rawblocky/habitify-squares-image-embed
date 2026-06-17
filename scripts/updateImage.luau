local net = require("@lune/net")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local DateTime = require("@lune/datetime")

local config = serde.decode("json", fs.readFile("config.json"))

local apiKey = process.env.HABITIFY_API_KEY
if not apiKey then
	apiKey = string.split(string.sub(fs.readFile(".env"), 18), "\n")[1]
end

local function request(url: string, cacheName: string)
	if cacheName and table.find(fs.readDir("/"), "cache") then
		local cacheDir = fs.readDir("cache")
		if table.find(cacheDir, cacheName .. ".json") then
			return serde.decode("json", fs.readFile(`cache/{cacheName}.json`))
		end
	end
	local response = net.request({
		url = url,
		method = "GET",
		headers = {
			["X-API-Key"] = apiKey,
		},
	})
	if not response.ok then
		warn(response.statusCode, response.statusMessage)
		return
	end

	local decoded = serde.decode("json", response.body)

	if cacheName then
		fs.writeFile(`cache/{cacheName}.json`, serde.encode("json", decoded))
	end

	return decoded
end

print("Getting habit journal")
local data = request("https://api.habitify.me/v2/habits/journal", "cacheData")

local allHabitStatistics = {}
local colorsPerHabit = {}
local daysSorted = {
	"Sun",
	"Mon",
	"Tue",
	"Wed",
	"Thu",
	"Fri",
	"Sat",
}
local monthsSorted = {
	"Jan",
	"Feb",
	"Mar",
	"Apr",
	"May",
	"Jun",
	"Jul",
	"Aug",
	"Sep",
	"Oct",
	"Nov",
	"Dec",
}

local shownHabits = {}
for _, habit in config.habits do
	table.insert(shownHabits, habit.name)
end
for _, habitBaseInfo in data.data do
	if not table.find(shownHabits, habitBaseInfo.name) then
		continue
	end
	print(`Retrieving habit statistics for '{habitBaseInfo.name}'`)
	local habitStatistics = request(`https://api.habitify.me/v2/habits/{habitBaseInfo.id}/statistics`, habitBaseInfo.id)
	allHabitStatistics[habitBaseInfo.name] = habitStatistics.data
	colorsPerHabit[habitBaseInfo.name] = habitBaseInfo.color
end

local svg = {
	'<rect width="100%" height="100%" fill="#0D1116" rx="12"/>',
}

local maxXAxis = 500
local currentYAxis = 20

for _, habitConfig in config.habits do
	local habitStatistics = allHabitStatistics[habitConfig.name]
	if not habitStatistics then
		continue
	end
	currentYAxis += (20 / 14) * 24
	table.insert(
		svg,
		`<text x="20" y="{currentYAxis - 7}" font-family="sans-serif" font-size="24" fill="white">{habitConfig.displayName or habitConfig.name}</text>`
	)
	currentYAxis += (20 / 14) * 24
	local totalData = {}
	local dataPerDay = {}
	local startAtDay = ""
	for index = 1, config.maxDays, 1 do
		local squareInfo = habitStatistics.dailyProgress[#habitStatistics.dailyProgress - index + 1]
		local dateTime
		if not squareInfo then
			if not totalData[1] or not config.fillUpMissingDays then
				break
			end
			-- Work backwards
			dateTime = DateTime.fromUnixTimestamp(totalData[1].unixTimestamp - (24 * 60 * 60))
		else
			dateTime = DateTime.fromRfc3339(`{squareInfo.date}T00:00:00Z`)
		end
		local day = string.sub(dateTime:toRfc2822(), 1, 3)
		if not dataPerDay[day] then
			dataPerDay[day] = {}
		end
		local sentData = {
			date = squareInfo and squareInfo.date or string.sub(dateTime:toIsoDate(), 1, 10),
			status = squareInfo and squareInfo.completed or "failed",
			totalLog = squareInfo and squareInfo.totalLog or 0,
			unixTimestamp = dateTime.unixTimestamp,
		}
		table.insert(dataPerDay[day], 1, sentData)
		table.insert(totalData, 1, sentData)

		startAtDay = day
	end
	local monthHeaderAxis = currentYAxis
	for index, day in daysSorted do
		local dayData = dataPerDay[day]
		if not dayData then
			continue
		end
		currentYAxis += 20
		local currentXAxis = 40
		table.insert(
			svg,
			`<text x="{currentXAxis}" y="{currentYAxis - 7}" font-family="sans-serif" font-size="14" fill="white">{day}</text>`
		)
		currentXAxis += 40
		if index < (table.find(daysSorted, startAtDay) or 99) then
			currentXAxis += 15
		end
		for _, squareInfo in dayData do
			local squareColor = "#151B23"
			for _, colorInfo in habitConfig.colors do
				if squareInfo.totalLog < colorInfo.minValue then
					break
				end
				squareColor = colorInfo.color
			end
			table.insert(
				svg,
				`<rect x="{currentXAxis}" y="{currentYAxis - 18}" width="12" height="12" rx="2" fill="{squareColor}"/>`
			)
			local dateTime = DateTime.fromUnixTimestamp(squareInfo.unixTimestamp)
			local universalTime = dateTime:toUniversalTime()
			if universalTime.day == 1 then
				local monthName = monthsSorted[universalTime.month]
				table.insert(
					svg,
					`<text x="{currentXAxis}" y="{monthHeaderAxis - 7}" font-family="sans-serif" font-size="14" fill="white">{monthName}</text>`
				)
			end
			currentXAxis += 15
		end
		maxXAxis = math.max(maxXAxis, currentXAxis)
	end
	currentYAxis += 20
end

table.insert(svg, 1, `<svg xmlns="http://www.w3.org/2000/svg" width="{maxXAxis + 20}" height="{currentYAxis + 20}">`)
table.insert(svg, "</svg>")
local svgString = table.concat(svg, "")
fs.writeFile("output.svg", svgString)
