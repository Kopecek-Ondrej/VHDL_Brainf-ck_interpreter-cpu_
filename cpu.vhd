-- cpu.vhd: Simple 8-bit CPU (BrainFuck interpreter)
-- Copyright (C) 2025 Brno University of Technology,
--                    Faculty of Information Technology
-- Author(s): Ondřej Kopeček <xkopeco00 AT stud.fit.vutbr.cz>
--
library ieee;
use ieee.std_logic_1164.all;
-- use ieee.numeric_std.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

-- ----------------------------------------------------------------------------
--                        Entity declaration
-- ----------------------------------------------------------------------------
entity cpu is
 port (
   CLK   : in std_logic;  -- hodinovy signal
   RESET : in std_logic;  -- asynchronni reset procesoru
   EN    : in std_logic;  -- povoleni cinnosti procesoru
 
   -- synchronni pamet RAM
   DATA_ADDR  : out std_logic_vector(12 downto 0); -- adresa do pameti
   DATA_WDATA : out std_logic_vector(7 downto 0); -- mem[DATA_ADDR] <- DATA_WDATA pokud DATA_EN='1'
   DATA_RDATA : in std_logic_vector(7 downto 0);  -- DATA_RDATA <- ram[DATA_ADDR] pokud DATA_EN='1'
   DATA_RDWR  : out std_logic;                    -- cteni (1) / zapis (0)
   DATA_EN    : out std_logic;                    -- povoleni cinnosti
   
   -- vstupni port
   IN_DATA   : in std_logic_vector(7 downto 0);   -- IN_DATA <- stav klavesnice pokud IN_VLD='1' a IN_REQ='1'
   IN_VLD    : in std_logic;                      -- data platna
   IN_REQ    : out std_logic;                     -- pozadavek na vstup data
   
   -- vystupni port
   OUT_DATA : out  std_logic_vector(7 downto 0);  -- zapisovana data
   OUT_BUSY : in std_logic;                       -- LCD je zaneprazdnen (1), nelze zapisovat
   OUT_INV  : out std_logic;                      -- pozadavek na aktivaci inverzniho zobrazeni (1)
   OUT_WE   : out std_logic;                      -- LCD <- OUT_DATA pokud OUT_WE='1' a OUT_BUSY='0'

   -- stavove signaly
   READY    : out std_logic;                      -- hodnota 1 znamena, ze byl procesor inicializovan
   DONE     : out std_logic                       -- hodnota 1 znamena, ze procesor ukoncil vykonavani programu (narazil na instrukci halt)
 );
end cpu;


-- ----------------------------------------------------------------------------
--                      Architecture declaration
-- ----------------------------------------------------------------------------
architecture behavioral of cpu is
  --PC(program counter signals)
  signal pc_reg_inc : std_logic;
  signal pc_reg_dec : std_logic;
  signal pc_reg_rst : std_logic; -- once we find @ we reset pc <-0, todo the top of the program
  signal pc_reg_mx1 : unsigned(12 downto 0); -- nase pamet ma 8kB = 2^13 b
  --PTR(ptr signals)
  signal ptr_reg_inc : std_logic;
  signal ptr_reg_dec : std_logic;
  signal ptr_reg_rst : std_logic;
  signal ptr_reg_mx1 : unsigned(12 downto 0); -- nase pamet ma 8kB = 2^13 b
  --CNT(cnt signals)
  signal cnt_reg_inc : std_logic;
  signal cnt_reg_dec : std_logic;
  signal cnt_reg_set : std_logic; -- sets the counter on '1'...it seem convenient according to the assignment
  signal cnt_reg_is_zero : unsigned(12 downto 0); -- i assume there will be not more than 2^13 brackets
  signal is_cnt_zero : std_logic;
  --decoder1 signals
  type instruction_type is (inc_ptr, dec_ptr, inc_mem_cell, dec_mem_cell, l_bracket, r_bracket,
                          l_paren, r_paren, print_mem_cell, store_mem_cell, values, at_symbol, zero_data, other);
  signal decode_data_rdata : instruction_type;
  -- mx1 signal
  signal sel_mx1 : std_logic; --from fsm to mx1
  --decoder2 signal- bloc before mx2
  signal decode2_out : std_logic_vector(7 downto 0);
  -- decrement block before mx2
  signal dec_out : std_logic_vector(7 downto 0);
  --increment block before mx2
  signal inc_out : std_logic_vector(7 downto 0);
  --select signal from FSM to mx2
  signal sel_mx2 : std_logic_vector(1 downto 0);

  --fsm present state (extended to include all referenced states)
  type fsm_state is (
    s_idle,
    -- s_init,
    s_look_for_at,
    s_check_for_at,
    s_found_at,
    s_fetch0,
    s_decode,
    s_inc_ptr,
    s_dec_ptr,
    s_inc_mem_cell,
    s_inc_mem_cell_1,
    s_dec_mem_cell,
    s_dec_mem_cell_1,
    s_values,
    s_store_mem_cell,
    s_store_mem_cell_wait,
    s_store_mem_cell_write,
    s_print_mem_cell,
    s_print_mem_cell_set_output,
    s_print_mem_cell_output,
    s_l_bracket,
    s_l_bracket_mem_check,
    s_l_bracket_get_data,
    s_l_bracket_check_data,
    s_l_bracket_check_cnt,
    s_r_bracket,
    s_r_bracket_mem_check,
    s_r_bracket_get_data,
    s_r_bracket_check_data,
    s_r_bracket_check_cnt,
    s_l_paren,
    s_r_paren,
    s_r_paren_mem_check,
    s_r_paren_get_data,
    s_r_paren_check_data,
    s_r_paren_check_cnt,
    s_halt,
    s_other -- spare/sentinel state
  );
  signal pstate : fsm_state;
  signal nstate : fsm_state;

begin

-- _________PC_(program counter)____konstrukce process
pc_reg: process(RESET, CLK)
begin
  if(RESET = '1') then
    pc_reg_mx1 <= (others=>'0');
  elsif (CLK'event) and (CLK='1') then
    if (pc_reg_inc = '1') then
      pc_reg_mx1 <= pc_reg_mx1 + 1;
    elsif(pc_reg_dec = '1') then
      pc_reg_mx1 <= pc_reg_mx1 - 1;
    elsif(pc_reg_rst = '1') then
      pc_reg_mx1 <= (others=>'0');
    end if;
  end if;
end process;

--__________PTR___konstrukce process
ptr_reg: process(RESET, CLK)
begin
  if(RESET = '1') then
    ptr_reg_mx1 <= (others=>'0');
  elsif(CLK'event) and (CLK='1') then
    if(ptr_reg_inc = '1') then
      ptr_reg_mx1 <= ptr_reg_mx1 + 1;
    elsif(ptr_reg_dec = '1') then
      ptr_reg_mx1 <= ptr_reg_mx1 - 1;
    elsif(ptr_reg_rst = '1') then
      ptr_reg_mx1 <= (others=>'0');
    end if;
  end if;
end process;

--__________CNT___konstrukce process
cnt_reg: process(RESET, CLK)
begin
  if(RESET = '1') then
    cnt_reg_is_zero <= (others=>'0');
  elsif(CLK'event) and (CLK='1') then
    if(cnt_reg_inc = '1') then
      cnt_reg_is_zero <= cnt_reg_is_zero + 1;
    elsif(cnt_reg_dec = '1') then
      cnt_reg_is_zero <= cnt_reg_is_zero - 1;
    elsif(cnt_reg_set = '1') then
      cnt_reg_is_zero <= "0000000000001";
    end if;
  end if;
end process;

--______zero_comparator
-- concurrent comparator: '1' when count is zero, else '0'
-- is_cnt_zero <= '1' when cnt_reg_is_zero = to_unsigned(0, cnt_reg_is_zero'length) else '0'; -- this was with old libraries
is_cnt_zero <= '1' when conv_integer(cnt_reg_is_zero) = 0 else '0'; -- with new libraries

--___dec_(instruction_decoder)
-- combinational decoder
decode_proc1: process(DATA_RDATA)
begin
  case DATA_RDATA is
    when x"3E" => decode_data_rdata <= inc_ptr;
    when x"3C" => decode_data_rdata <= dec_ptr;
    when x"2B" => decode_data_rdata <= inc_mem_cell;
    when x"2D" => decode_data_rdata <= dec_mem_cell;
    when x"5B" => decode_data_rdata <= l_bracket;
    when x"5D" => decode_data_rdata <= r_bracket;
    when x"28" => decode_data_rdata <= l_paren;
    when x"29" => decode_data_rdata <= r_paren;
    when x"2E" => decode_data_rdata <= print_mem_cell;
    when x"2C" => decode_data_rdata <= store_mem_cell;
    when x"30" | x"31" | x"32" | x"33" | x"34" |       
          x"35" | x"36" | x"37" | x"38" | x"39" |
          x"41" | x"42" | x"43" | x"44" | x"45" | x"46" =>  --for a-f
      decode_data_rdata <= values;
    when x"40" => decode_data_rdata <= at_symbol;
    when x"00" => decode_data_rdata <= zero_data;
  when others => -- we assume only correct programs
    decode_data_rdata <= other; -- default is for safety
  end case;
end process;

with sel_mx1 select
  DATA_ADDR <= std_logic_vector(ptr_reg_mx1) when '0',
               std_logic_vector(pc_reg_mx1) when '1',
               (others => '0') when others;

-- __dec___decodr that goes to mx2
-- it only makes from character '0' - '9' and 'A' - 'F' a coresponding number in binary
decode_proc2: process(DATA_RDATA)
begin
  case DATA_RDATA is
    when x"30" => decode2_out <= x"00";
    when x"31" => decode2_out <= x"10";
    when x"32" => decode2_out <= x"20";
    when x"33" => decode2_out <= x"30";
    when x"34" => decode2_out <= x"40";
    when x"35" => decode2_out <= x"50";
    when x"36" => decode2_out <= x"60";
    when x"37" => decode2_out <= x"70";
    when x"38" => decode2_out <= x"80";
    when x"39" => decode2_out <= x"90";
    -- Uppercase hex letters A..F
    when x"41" => decode2_out <= x"A0";
    when x"42" => decode2_out <= x"B0";
    when x"43" => decode2_out <= x"C0";
    when x"44" => decode2_out <= x"D0";
    when x"45" => decode2_out <= x"E0";
    when x"46" => decode2_out <= x"F0";
    when others => decode2_out <= x"00";
  end case;
end process;

--a block that decrements DATA_RDATA
-- one of the inputs of mx2
-- dec_out <= std_logic_vector(unsigned(DATA_RDATA) - 1); --old library
dec_out <= conv_std_logic_vector(conv_integer(DATA_RDATA) - 1, DATA_RDATA'length); -- newlibrary

-- a block that increments DATA_RDATA
-- one of the inputs of mx2
-- inc_out <= std_logic_vector(unsigned(DATA_RDATA) + 1); --old library
inc_out <= conv_std_logic_vector(conv_integer(DATA_RDATA) + 1, DATA_RDATA'length);--new library
--mx2
with sel_mx2 select
  DATA_WDATA <= IN_DATA     when "00",
               decode2_out when "01",
               dec_out     when "10",
               inc_out     when "11",
               (others => '0') when others;
--fsm present state
fsm_pstate_reg: process (RESET, CLK)
  begin
    if(RESET = '1') then
      pstate <= s_idle;
    elsif(CLK'event) and (CLK='1') then
      if(EN = '1') then
        pstate <= nstate;
      end if;
      -- pstate <= nstate;
    end if;
end process;

next_state_logic : process(pstate, EN, OUT_BUSY, IN_VLD, is_cnt_zero, decode_data_rdata)
begin
  READY <= '1';   --represent idle state
  DONE <= '0';    --represent idle state
  OUT_INV <= '0';
  OUT_WE <= '0';
  OUT_DATA <= (others => '0');
  IN_REQ <= '0';
  DATA_EN <= '0';
  DATA_RDWR <= '0';
  cnt_reg_inc <= '0';
  cnt_reg_dec <= '0';
  cnt_reg_set <= '0';
  ptr_reg_inc <= '0';
  ptr_reg_dec <= '0';
  ptr_reg_rst <= '0';
  pc_reg_inc <= '0';
  pc_reg_dec <= '0';
  pc_reg_rst <= '0';
  sel_mx1 <= '0';
  sel_mx2 <= "00";

  case pstate is
    when s_idle =>
      if(EN = '1') then
        nstate <= s_look_for_at;
      elsif(EN = '0') then
        nstate <= s_idle;
      end if;
      READY <= '0';
      -- nstate <= s_look_for_at;
-- first we look for @ by fetching 
    when s_look_for_at =>
      --fetch
      sel_mx1 <= '1';
      DATA_EN <= '1';
      DATA_RDWR <= '1';
      READY <= '0';
      --check for @
      nstate <= s_check_for_at;
    when s_check_for_at =>
      case decode_data_rdata is
        when at_symbol => 
          nstate <= s_found_at;
        when others =>
          ptr_reg_inc <= '1';
          pc_reg_inc <= '1';
          nstate <= s_look_for_at;
      end case;
      READY <= '0';
    when s_found_at =>
      pc_reg_rst <= '1';
      ptr_reg_inc <= '1'; -- point behind @
      nstate <= s_fetch0;
-- universal fetch state
    when s_fetch0 =>
      sel_mx1 <= '1';
      DATA_RDWR <= '1';
      DATA_EN <= '1';
      nstate <= s_decode;
--decode state
    when s_decode =>
      case decode_data_rdata is
        when inc_ptr =>
          -- increment pointer
          nstate <= s_inc_ptr;
        when dec_ptr =>
          -- decrement pointer
          nstate <= s_dec_ptr;
        when inc_mem_cell =>
          -- increment memory cell
          nstate <= s_inc_mem_cell;
        when dec_mem_cell =>
          -- decrement memory cell
          nstate <= s_dec_mem_cell;
        when l_bracket =>
          -- '[' : handle loop start
          nstate <= s_l_bracket;
        when r_bracket =>
          -- ']' : handle loop end
          nstate <= s_r_bracket;
        when l_paren =>
          -- '(' : alternative bracket
          nstate <= s_l_paren;
        when r_paren =>
          -- ')' : alternative bracket
          nstate <= s_r_paren;
        when print_mem_cell =>
          -- output memory cell
          nstate <= s_print_mem_cell;
        when store_mem_cell =>
          -- store memory cell
          nstate <= s_store_mem_cell;
        when values =>
          -- immediate/value handling
          nstate <= s_values;
        when at_symbol =>
          -- special symbol '@'
          nstate <= s_halt;
        when other =>
          -- unknown / default
          nstate <= s_other;
        when zero_data =>
          nstate <= s_idle;
      end case;
--individual execution branches
    when s_inc_ptr =>
      ptr_reg_inc <= '1'; -- ptr<-- ptr + 1 % 0x2000
      pc_reg_inc <= '1';  -- pc <-- pc + 1
      nstate <= s_fetch0;
    when s_dec_ptr =>
      ptr_reg_dec <= '1'; -- ptr <-- ptr - 1 & 0x2000
      pc_reg_inc <= '1';  -- pc <-- pc + 1
      nstate <= s_fetch0;
-- for increment mem cell value
    when s_inc_mem_cell =>
      sel_mx1<= '0'; -- ptr
      DATA_EN <= '1'; --  
      DATA_RDWR <= '1'; -- DATA_RDATA <-- mem[ptr]
      nstate <= s_inc_mem_cell_1;
    when s_inc_mem_cell_1 =>
      sel_mx1 <= '0'; -- adress of ptr
      DATA_EN <= '1';
      DATA_RDWR <= '0'; --WRITE
      sel_mx2 <= "11"; -- mem[ptr] <-- DATA_RDATA + 1
      pc_reg_inc <= '1'; -- pc <-- pc + 1
      nstate <= s_fetch0;
-- for decrement mem cell value
    when s_dec_mem_cell =>
      sel_mx1 <= '0'; --adress of ptr
      DATA_EN <= '1';
      DATA_RDWR <= '1';
      nstate <= s_dec_mem_cell_1;
    when s_dec_mem_cell_1 =>
      sel_mx1 <= '0';
      DATA_EN <= '1';
      DATA_RDWR <= '0'; -- WRITE
      sel_mx2 <= "10"; -- mem[ptr] <-- DATA_RDATA - 1
      pc_reg_inc <= '1';
      nstate <= s_fetch0;
-- for values to be store in a weird way
    when s_values =>
      sel_mx1 <= '0'; -- mem[ptr]
      DATA_EN <= '1'; --
      DATA_RDWR <= '0'; -- write
      sel_mx2 <= "01"; -- chooses to decode the value
      pc_reg_inc <= '1'; -- pc <-- pc + 1;
      nstate <= s_fetch0;
-- for store_mem_cell
    when s_store_mem_cell =>
      IN_REQ <= '1';
      nstate <= s_store_mem_cell_wait;
    when s_store_mem_cell_wait =>
      if(IN_VLD = '0') then -- if IN_VLD is 0 return back to s_store_mem_cell until it is ='1'
        nstate <= s_store_mem_cell;
      elsif(IN_VLD = '1') then
        nstate <= s_store_mem_cell_write;
      end if;
    when s_store_mem_cell_write =>
      sel_mx1 <= '0'; -- mem[ptr] --prisk:: mozna se to predbiha
      sel_mx2 <= "00"; -- <--IN_DATA
      DATA_EN <= '1';
      DATA_RDWR <= '0'; -- WRITE
      pc_reg_inc <= '1';
      nstate <= s_fetch0;
-- for print mem cell
    when s_print_mem_cell =>
    --   nstate <= s_print_mem_cell_wait;
    -- when s_print_mem_cell_wait =>
      if(OUT_BUSY = '1') then
        nstate <= s_print_mem_cell;
      elsif(OUT_BUSY = '0') then
        nstate <= s_print_mem_cell_set_output;
      end if;
    when s_print_mem_cell_set_output =>
      sel_mx1 <= '0'; -- mem[ptr]
      DATA_EN <= '1';
      DATA_RDWR <= '1'; -- READ
      nstate <= s_print_mem_cell_output;
    when s_print_mem_cell_output =>
      OUT_DATA <= DATA_RDATA;
      OUT_WE <= '1';
      OUT_INV <= '0';
      pc_reg_inc <= '1';
      nstate <= s_fetch0;
-- for l_bracket '['
    when s_l_bracket =>
      pc_reg_inc <= '1'; 
      sel_mx1 <= '0'; -- mem[ptr]
      DATA_EN <= '1';
      DATA_RDWR <= '1'; -- provide data in mem[ptr]
      nstate <= s_l_bracket_mem_check;
    when s_l_bracket_mem_check =>
      if(decode_data_rdata = zero_data) then -- if(mem[ptr] == 0)
        cnt_reg_set <= '1'; -- CNT <-- 1
        nstate <= s_l_bracket_get_data; -- we must find the coresponding ]
      elsif(decode_data_rdata /= zero_data) then
        nstate <= s_fetch0; --continue ...pc is already incremented
      end if;
    when s_l_bracket_get_data =>
    --fetch instructions
      sel_mx1 <= '1';-- mem[pc]
      DATA_EN <= '1'; --
      DATA_RDWR <= '1'; -- READ
      nstate <= s_l_bracket_check_data;
    when s_l_bracket_check_data =>
      if(decode_data_rdata = r_bracket) then
        cnt_reg_dec <= '1';
      elsif(decode_data_rdata = l_bracket) then
        cnt_reg_inc <= '1';
      end if;
      nstate <= s_l_bracket_check_cnt;
    when s_l_bracket_check_cnt =>
      if(is_cnt_zero = '1') then
        nstate <= s_fetch0;
      elsif(is_cnt_zero = '0') then
        nstate <= s_l_bracket_get_data;
      end if;
      pc_reg_inc <= '1';
--for r_bracket ']'________________
    when s_r_bracket =>
      --fetch
      sel_mx1 <= '0'; -- mem[ptr]
      DATA_EN <= '1';
      DATA_RDWR <= '1';
      nstate <= s_r_bracket_mem_check;
    when s_r_bracket_mem_check =>
      if(decode_data_rdata = zero_data) then
        pc_reg_inc <= '1';
        nstate <= s_fetch0;
      elsif(decode_data_rdata /= zero_data) then
        nstate <= s_r_bracket_get_data;
        cnt_reg_set <= '1';
        pc_reg_dec <= '1';
      end if;
    when s_r_bracket_get_data =>
      --fetch
      sel_mx1 <= '1'; --mem[pc]
      DATA_EN <= '1';
      DATA_RDWR <= '1'; -- READ
      nstate <= s_r_bracket_check_data;
    when s_r_bracket_check_data =>
      if(decode_data_rdata = r_bracket) then
        cnt_reg_inc <= '1';
      elsif(decode_data_rdata = l_bracket) then
        cnt_reg_dec <= '1';
      end if;
      nstate <= s_r_bracket_check_cnt;
    when s_r_bracket_check_cnt =>
      if(is_cnt_zero = '1') then
        nstate <= s_fetch0;
        pc_reg_inc <= '1'; -- pc += 1 because we start with the first instruction after '['
      elsif(is_cnt_zero = '0') then
        nstate <= s_r_bracket_get_data;
        pc_reg_dec <= '1'; --keep on looking backward in instructions
      end if;
-- for s_l_paren '('_____
    when s_l_paren =>
      pc_reg_inc <= '1';
      nstate <= s_fetch0;
-- for s_r_paren ')'___________
    when s_r_paren =>
      --fetch
      sel_mx1 <= '0'; -- mem[ptr]
      DATA_EN <= '1';
      DATA_RDWR <= '1'; -- READ
      nstate <= s_r_paren_mem_check;
    when s_r_paren_mem_check =>
      if(decode_data_rdata = zero_data) then
        pc_reg_inc <= '1';
        nstate <= s_fetch0;
      elsif(decode_data_rdata /= zero_data) then
        cnt_reg_set <= '1';
        pc_reg_dec <= '1';
        nstate <= s_r_paren_get_data;
      end if;
    when s_r_paren_get_data =>
    --fetch
      sel_mx1 <= '1'; -- mem[pc]
      DATA_EN <= '1';
      DATA_RDWR <= '1';
      nstate <= s_r_paren_check_data;
    when s_r_paren_check_data => 
      if(decode_data_rdata = l_paren) then
        cnt_reg_dec <= '1';
      elsif(decode_data_rdata = r_paren) then
        cnt_reg_inc <= '1';
      end if;
      nstate <= s_r_paren_check_cnt;
    when s_r_paren_check_cnt =>
      if(is_cnt_zero = '1') then
        nstate <= s_fetch0;
        pc_reg_inc <= '1';
      elsif(is_cnt_zero = '0') then
        nstate <= s_r_paren_get_data;
        pc_reg_dec <= '1';
      end if;
-- for at_symbol @
    when s_halt =>
      DONE <= '1';
      nstate <= s_idle;
--for others
    when others =>
      pc_reg_inc <= '1';
      nstate <= s_fetch0;



  end case;
      end process;

end behavioral;