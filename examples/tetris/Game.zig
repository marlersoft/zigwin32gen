const Game = @This();

const std = @import("std");

const win32 = struct {
    usingnamespace @import("win32").zig;
};

const DrawEngine = @import("DrawEngine.zig");
const Level = @import("Level.zig");

level: Level,
de: *DrawEngine,
isPaused: bool,

pub fn init(de: *DrawEngine) Game {
    return Game {
        .level = Level { .de = de },
        .de = de,
        .isPaused = false,
    };
}

//pub fn deinit(self: Game) void {
//}

fn drawGameOver(self: Game) void {
    self.de.drawText(win32._T("GAME OVER"), 3, 10);
    self.de.drawText(win32._T("Press ENTER to restart"), 2, 9);
}

fn drawPause(self: Game) void {
    self.de.drawText(win32._T("PAUSE"), 4, 10);
    self.de.drawText(win32._T("Press PAUSE again to continue"), 1, 9);
}

//void Game::restart()
//{
//    delete level;
//    level = new Level(de, 10, 20);
//    isPaused = false;
//    repaint();
//}
//
//bool Game::keyPress(int vk)
//{
//    // When pausing, ignore keys other than PAUSE and ENTER
//    if (vk != VK_PAUSE && vk != VK_RETURN && isPaused)
//        return false;
//
//    switch (vk)
//    {
//        case VK_UP:
//            level->rotate();
//            break;
//        case VK_DOWN:
//            level->move(0, -1);
//            break;
//        case VK_LEFT:
//            level->move(-1, 0);
//            break;
//        case VK_RIGHT:
//            level->move(1, 0);
//            break;
//        case VK_SPACE:
//            level->rotate();
//            break;
//        case VK_PAUSE:
//            pause(!isPaused);
//            break;
//        case VK_RETURN:
//            // You can only restart on game over
//            if (level->isGameOver())
//                restart();
//        default:
//            return false;
//    }
//    return true;
//}
//
pub fn timerUpdate(self: *Game) void {
    if (self.isPaused)
        return;

    if (self.level.isGameOver()) {
        self.isPaused = true;
        self.drawGameOver();
        return;
    }
    self.level.timerUpdate();
    self.level.drawBoard();
}

pub fn pause(self: *Game, paused: bool) void {
    if (self.level.isGameOver())
        return;
    self.isPaused = paused;
    if (paused)
        self.drawPause();
    //self.level.drawScore();
    //self.level.drawSpeed();
}

pub fn repaint(self: Game) void {
    self.de.drawInterface();
    self.level.drawScore();
    self.level.drawSpeed();
    //level->drawNextPiece();
    self.level.drawBoard();
    //if (level->isGameOver())
    //    drawGameOver();
    //else if (isPaused)
    //    drawPause();
}
