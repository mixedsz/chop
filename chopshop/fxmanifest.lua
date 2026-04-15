shared_script '@WaveShield/resource/include.lua'

fx_version 'cerulean'
game 'gta5'

author 'Chop Shop'
description 'ESX Chop Shop - Strip whitelisted donor cars for parts'
version '1.0.0'

dependencies {
    'es_extended',
}

shared_scripts {
    '@es_extended/imports.lua',
    'config.lua',
}

client_scripts {
    'client/main.lua',
}

server_scripts {
    'server/main.lua',
}

lua54 'yes'
