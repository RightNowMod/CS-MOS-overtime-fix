#include <sourcemod>
#include <sdktools>
#include <cstrike>

#pragma semicolon 1
#pragma newdecls required

#define RESTART_TIME 20 // 重启倒计时

// 插件信息
public Plugin myinfo = {
    name = "CSMOS加时赛修复",
    author = "DeepDC",
    description = "修复CSMOS启用加时赛以后，无法正常结束游戏的问题。目前比赛可以正常结束，结束后会自动刷服开启下一把，默认使用原地图，如果你想用mapcycle需要自己写。",
    version = "1.0",
    url = "https://irn.top"
};

// 变量定义
bool g_bHeadshotOnly = true; // 是否开启爆头模式
bool g_bInfiniteAmmo = true; // 是否开启无限弹药
int g_iPlayerKills[MAXPLAYERS + 1]; // 玩家击杀数
char g_roomId[32]; // Room ID

ConVar g_Cvar_maxRounds; // max rounds
int g_TotalRounds = 0; // current round
int g_ctWinRounds = 0; // CT win rounds
int g_tWinRounds = 0; // T win rounds

bool g_isInOverTime = false; // is currently overtime
int g_ctOvertimeWinRounds = 0; // CT win rounds
int g_tOvertimeWinRounds = 0; // T win rounds

bool isHalfTimeTriggered = false; // 是否触发半场切换
bool isOverTimeHalfTimeTriggered = false; // 是否触发加时赛半场切换

ConVar g_Cvar_winLimit; // any team reach this win rounds, then game over
ConVar g_Cvar_mp_respawn_on_death_ct;
ConVar g_Cvar_mp_respawn_on_death_t;
ConVar g_Cvar_mp_ignore_round_win_conditions;
ConVar g_Cvar_mp_overtime_maxrounds;
ConVar g_Cvar_mp_overtime_enable;
char error[255];
Database db;

Handle g_timer; // 设置定时器
int g_remainingTime = RESTART_TIME;

// 插件初始化
public void OnPluginStart() {
    // 注册命令
    RegConsoleCmd("sm_weapons", Command_Weapons, "Open weapon selection menu");
    RegConsoleCmd("sm_rank", Command_Rank, "Show player rankings");

    // 事件挂钩
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("player_spawn", Event_PlayerSpawn);   
    HookEvent("game_start", Event_GameStart, EventHookMode_Post);
    HookEvent("player_disconnect", OnPlayerDisconnect, EventHookMode_Post);
    HookEvent("cs_win_panel_round", Event_CSSRoundEnd);
    HookEvent("round_end", Event_RoundEnd);
    HookEvent("cs_win_panel_match", Event_MatchEnd);

    // Server Config
    g_Cvar_maxRounds = FindConVar("mp_maxrounds"); // max round in each match
    g_Cvar_winLimit = FindConVar("mp_winlimit"); // cannot get, damn!
    g_Cvar_mp_respawn_on_death_ct = FindConVar("mp_respawn_on_death_ct");
    g_Cvar_mp_respawn_on_death_t = FindConVar("mp_respawn_on_death_t");
    g_Cvar_mp_ignore_round_win_conditions = FindConVar("mp_ignore_round_win_conditions");
    g_Cvar_mp_overtime_maxrounds = FindConVar("mp_overtime_maxrounds"); // 加时赛最大轮数 默认6，目前没有开放调节
    g_Cvar_mp_overtime_enable = FindConVar("mp_overtime_enable"); // 是否允许加时赛

    // 初始化击杀数
    for (int i = 1; i <= MaxClients; i++) {
        g_iPlayerKills[i] = 0;
    }

    InitDb(); // 初始化数据库
}

// 是否允许加时赛
bool isOverTimeEnabled() {
    return (g_Cvar_mp_overtime_enable.IntValue == 1);
}

// 是否为竞技模式
bool isCompetitiveMode() {
    return (g_Cvar_mp_respawn_on_death_ct.IntValue == 0 && g_Cvar_mp_respawn_on_death_t.IntValue == 0 && g_Cvar_mp_ignore_round_win_conditions.IntValue == 0);
}

/**
    初始化游戏局数
**/
void ResetGameRounds() {
    PrintToServer("[游戏] ResetGameRounds！");
    PrintToServer("[游戏] g_Cvar_maxRounds %d", g_Cvar_maxRounds.IntValue);
    PrintToServer("[游戏] g_Cvar_mp_overtime_maxrounds %d", g_Cvar_mp_overtime_maxrounds.IntValue);

    g_TotalRounds = 0;
    g_ctWinRounds = 0;
    g_tWinRounds = 0;
    isHalfTimeTriggered = false;
}

/**
    初始化加时赛参数
**/
void ResetOvertimeRounds(bool isStillInOverTime) {
    g_isInOverTime = isStillInOverTime;
    g_ctOvertimeWinRounds = 0;
    g_tOvertimeWinRounds = 0;
    isOverTimeHalfTimeTriggered = false;
}


//---------------------------------------- 事件 ----------------------------------------------//

/**
    游戏开始事件 CSMOS不干活
**/
public void Event_GameStart(Event event, const char[] name, bool dontBroadcast)
{
    PrintToServer("[游戏] Max Round set to %d！", g_Cvar_maxRounds.IntValue);
    PrintToServer("[游戏] Win limit set to %d！", g_Cvar_winLimit.IntValue);
	/* Game got restarted - reset our round count tracking */
	PrintToChatAll("[游戏] 比赛开始！");
    int maxRounds = event.GetInt("roundslimit");
    int timeLimit = event.GetInt("timelimit");
    int fragLimit = event.GetInt("fraglimit");
    char objective[64];
    event.GetString("objective", objective, sizeof(objective));

    PrintToServer("Game Start Event Triggered!");
    PrintToServer("Max Rounds: %d", maxRounds);
    PrintToServer("Time Limit: %d", timeLimit);
    PrintToServer("Frag Limit: %d", fragLimit);
    PrintToServer("Objective: %s", objective);
    ResetGameRounds();
}

/**
    一局结束事件 比CSS一局结束事件晚触发
**/
public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
    int winner = event.GetInt("winner");
    if (winner == 2)
    {
        PrintToServer("[RoundEnd] 恐怖分子(T) 获胜！");
        if (!g_isInOverTime) {
            g_tWinRounds++;
            PrintToServer("[RoundEnd] 恐怖分子(T) 已经赢了%d把！，反恐精英(CT) 已经赢了%d把！", g_tWinRounds, g_ctWinRounds);
        } else {
            g_tOvertimeWinRounds++;
        }
    }
    else if (winner == 3)
    {
        PrintToServer("[RoundEnd] 反恐精英(CT) 获胜！");
        if (!g_isInOverTime) {
            g_ctWinRounds++;
            PrintToServer("[RoundEnd] 反恐精英(CT) 已经赢了%d把！恐怖分子(T) 已经赢了%d把！", g_ctWinRounds, g_tWinRounds);
        } else {
            g_ctOvertimeWinRounds++;
        }
    }

    if (winner == 2 || winner == 3) {
        g_TotalRounds++;
        PrintToServer("[RoundEnd] 总共已经进行了%d轮比赛！总共%d轮", g_TotalRounds, g_Cvar_maxRounds.IntValue);

        if (g_TotalRounds >= (g_Cvar_maxRounds.IntValue / 2)) { // 半场切换准备 交换双方数据
            if (!isHalfTimeTriggered) {
                isHalfTimeTriggered = true;
                int ct_tmp = g_ctWinRounds;
                int t_tmp = g_tWinRounds;
                g_ctWinRounds = t_tmp;
                g_tWinRounds = ct_tmp;
                PrintToServer("[RoundEnd]半场切换");
            }
        }

        if (!g_isInOverTime && 
        (g_ctWinRounds > (g_Cvar_maxRounds.IntValue / 2) || g_tWinRounds > (g_Cvar_maxRounds.IntValue / 2))) { // 一方赢了
                PrintToServer("[RoundEnd] 游戏结束！");
                RestartGame();
                return;
        }
        if (g_TotalRounds >= g_Cvar_maxRounds.IntValue) {
            if (!isOverTimeEnabled()) { // 未开启加时赛
                PrintToServer("[RoundEnd] 游戏结束！");
                RestartGame(); // 结束比赛
                return;
            }
            if (!g_isInOverTime && g_ctWinRounds == g_tWinRounds) {
                g_isInOverTime = true; // 符合加时赛的条件，设置从下轮开始为加时赛
            } else { // 加时赛的情况
                if ((g_ctOvertimeWinRounds + g_tOvertimeWinRounds) >= (g_Cvar_mp_overtime_maxrounds.IntValue / 2)) { // 半场切换
                    if (!isOverTimeHalfTimeTriggered) {
                        isOverTimeHalfTimeTriggered = true;
                        int ct_tmp = g_ctOvertimeWinRounds;
                        int t_tmp = g_tOvertimeWinRounds;
                        g_ctOvertimeWinRounds = t_tmp;
                        g_tOvertimeWinRounds = ct_tmp;
                        PrintToServer("[RoundEnd]半场切换");
                    }
                }
                if (g_ctOvertimeWinRounds > (g_Cvar_mp_overtime_maxrounds.IntValue / 2) || g_tOvertimeWinRounds > (g_Cvar_mp_overtime_maxrounds.IntValue / 2)) {
                    // 加时赛分出胜负
                    PrintToServer("[RoundEnd] 游戏结束！");
                    RestartGame();
                    return;
                }
                if ((g_ctOvertimeWinRounds + g_tOvertimeWinRounds) >= g_Cvar_mp_overtime_maxrounds.IntValue) {
                    // 加时赛结束，没有分出胜负
                    ResetOvertimeRounds(true); // 重置加时赛
                }
            }
        }
    }
}

void RestartGame() {
    PrintToServer("[游戏] 结束比赛，重新进入地图");
    InitReloadMap();
    g_timer = CreateTimer(1.0, ReloadMap, _, TIMER_REPEAT);
}

/**
    CSS一局结束事件
**/
public void Event_CSSRoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    PrintToChatAll("[游戏] 回合结束");
    PrintToServer("[游戏] 回合结束");
    // 移动到上面的RoundEnd事件了
}

/**
    比赛结束事件，若开启加时赛，则无法触发(截止至CSMOSv8)
**/
public void Event_MatchEnd(Event event, const char[] name, bool dontBroadcast)
{
    InitCustomReloadMap(10);
    g_timer = CreateTimer(1.0, ReloadMap, _, TIMER_REPEAT); // 10秒内重置，防止给抢先了，他会自动换地图，我们需要比自动换地图早
	PrintToServer("[游戏] 比赛结束！");
	PrintToChatAll("[游戏] 比赛结束！");
}

public void OnMapStart()
{
    PrintToServer("[游戏] 地图开始！");
    PrintToChatAll("[游戏] 地图开始！");
    ResetGameRounds();
    InitReloadMap();
    ResetOvertimeRounds(false);
    FormatTime(g_roomId, sizeof(g_roomId), "%Y%m%d%H%M%S", GetTime()); // generate room id
}


public void OnMapEnd()
{
	PrintToServer("[游戏] 地图结束！");
	PrintToChatAll("[游戏] 地图结束！");
}

// 玩家重生事件
public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
}

// 玩家死亡事件
public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast) {
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int victim = GetClientOfUserId(event.GetInt("userid"));
    bool headshot = event.GetBool("headshot");
    char weapon[64];
    event.GetString("weapon", weapon, sizeof(weapon));

    char attackerName[32];
    GetClientName(attacker, attackerName, sizeof(attackerName));
    char victimName[32];
    GetClientName(victim, victimName, sizeof(victimName));
    bool isValidKill = 1;
    if (attacker == victim) { // self kill
        isValidKill = 0;
    }
    // 获取攻击者和受害者的队伍 2:ct, 3:t
    int attacker_team = GetClientTeam(attacker);
    int victim_team = GetClientTeam(victim);

    // 判断某一方玩家是否全部离开
    

    // PrintToChatAll("attacker: %s, victim: %s, headshot: %d, weapon: %s", attackerName, victimName, headshot, weapon);
    // ("isValidKill: %d, attacker_team: %d, victim_team: %d", isValidKill, attacker_team, victim_team);

    if (IsValidClient(attacker)) {
        // insert to database
        char queryStr[256];
        Format(queryStr, sizeof(queryStr),
        "INSERT INTO player_log SET room_id='%s', victim_name='%s', attacker_name='%s', headshot=%d, weapon='%s', valid_kill='%d', attacker_team='%d', victim_team='%d'",
        g_roomId, attackerName, victimName, headshot, weapon, isValidKill, attacker_team, victim_team);
        DbQuery(queryStr);
    }

    if (IsValidClient(attacker) && attacker != victim) {
        // 更新击杀数
        g_iPlayerKills[attacker]++;
        //PrintToChat(attacker, "你击杀了一名玩家！当前击杀数: %d", g_iPlayerKills[attacker]);

        // 爆头模式检查
        if (g_bHeadshotOnly && !event.GetBool("headshot")) {
            //PrintToChat(attacker, "只有爆头才能造成伤害！");
            return;
        }
    }
}

/**
    玩家离开事件
**/
public Action OnPlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    int userid = event.GetInt("userid");
    char reason[128];
    char pname[128];
    char steamid[64];
    int isBot = event.GetInt("bot");

    event.GetString("reason", reason, sizeof(reason));
    event.GetString("name", pname, sizeof(pname));
    event.GetString("networkid", steamid, sizeof(steamid));

    PrintToServer("[DISCONNECT] %s (%s) left the server. Reason: %s %s", 
        pname, steamid, reason, isBot ? "[BOT]" : "");

    CreateTimer(2.0, CheckPlayerCountAfterDisconnect);
    
    return Plugin_Handled;
}

// 判断队伍人数并根据状态处理
public Action CheckPlayerCountAfterDisconnect(Handle timer)
{
    int ctCount = GetTeamClientCount(CS_TEAM_CT);
    int tCount = GetTeamClientCount(CS_TEAM_T);

    // Step 3: 判断是否有队伍为空
    if (ctCount == 0 || tCount == 0)
    {
        bool isOvertime = g_isInOverTime == 1;

        if (isOvertime)
        {
            RestartGame();  // 比赛结束
        }
        else
        {
            ResetGameRounds(); // 重置局数，重新开始
            InitReloadMap();
            ResetOvertimeRounds(false);
        }
    }

    return Plugin_Handled;
}
//---------------------------------------- 事件结束 ----------------------------------------------//


// 初始化数据库
void InitDb() {
    char error[255];
    db = SQL_DefConnect(error, sizeof(error));
 
    if (db == null)
    {
        PrintToServer("无法连接到数据库: %s", error);
    } 
}

// 执行SQL语句
int DbQuery(char[] sql) {
    if (!SQL_FastQuery(db, sql))
    {
        char error[255];
        SQL_GetError(db, error, sizeof(error));
        PrintToServer("执行SQL语句失败 (error: %s)", error);
    }
}

/**
    初始化加载地图
**/
void InitReloadMap() {
    g_remainingTime = RESTART_TIME; // 重置倒计时

}

void InitCustomReloadMap(int second) {
    g_remainingTime = second; // 重置倒计时
}

/**
    重新加载地图
    用 g_timer = CreateTimer(1.0, ReloadMap, _, TIMER_REPEAT); 开启
**/
public Action ReloadMap(Handle timer, any value) {
    // PrintToChatAll("[系统] 比赛结束，5 秒后将重新开始新一场比赛。");
    g_remainingTime--;
    if (g_remainingTime % 10 == 0) {
        PrintToChatAll("倒计时剩余 %d 秒", g_remainingTime);
    }
     // 倒计时结束，重启服务器
    if (g_remainingTime <= 0) {
        PrintToChatAll("服务器重启中...");
        KillTimer(g_timer); // 停止倒计时
        char map[64];
        GetCurrentMap(map, sizeof(map));
        ServerCommand("changelevel %s", map); // 重新加载地图
    }
}

// 玩家选择武器菜单
public Action Command_Weapons(int client, int args) {
    if (IsValidClient(client)) {
        ShowWeaponMenu(client);
    }
    return Plugin_Handled;
}

// 显示武器菜单
void ShowWeaponMenu(int client) {
    Menu menu = new Menu(WeaponMenuHandler);
    menu.SetTitle("选择你的主武器:");
    menu.AddItem("weapon_ak47", "AK47");
    menu.AddItem("weapon_m4a1", "M4A1");
    menu.AddItem("weapon_awp", "AWP");
    menu.AddItem("weapon_deagle", "Desert Eagle");
    menu.Display(client, MENU_TIME_FOREVER);
}

// 武器菜单回调
public int WeaponMenuHandler(Menu menu, MenuAction action, int client, int itemNum) {
    if (action == MenuAction_Select && IsValidClient(client)) {
        char weapon[32];
        menu.GetItem(itemNum, weapon, sizeof(weapon));
        GivePlayerWeapon(client, weapon);
    }
    return 0;
}

// 给予玩家武器
void GivePlayerWeapon(int client, const char[] weapon) {
    if (IsValidClient(client)) {
        int weaponEnt = GivePlayerItem(client, weapon);
        if (weaponEnt != -1) {
            EquipPlayerWeapon(client, weaponEnt);
        }
    }
}


// 显示排行榜
public Action Command_Rank(int client, int args) {
    if (IsValidClient(client)) {
        ShowRankMenu(client);
    }
    return Plugin_Handled;
}

// 显示排行榜菜单
void ShowRankMenu(int client) {
    Menu menu = new Menu(RankMenuHandler);
    menu.SetTitle("玩家排行榜:");

    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i)) {
            char playerName[32];
            GetClientName(i, playerName, sizeof(playerName));
            char display[64];
            Format(display, sizeof(display), "%s - %d 击杀", playerName, g_iPlayerKills[i]);
            menu.AddItem("", display, ITEMDRAW_DISABLED);
        }
    }

    menu.Display(client, MENU_TIME_FOREVER);
}

// 排行榜菜单回调
public int RankMenuHandler(Menu menu, MenuAction action, int client, int itemNum) {
    return 0;
}

// 检查客户端是否有效
bool IsValidClient(int client) {
    return client > 0 && client <= MaxClients && IsClientInGame(client);
}
