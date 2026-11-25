-------------------------------------------------------------------------------
-- Title         : DAC AD5781 Interface
-------------------------------------------------------------------------------
-- File          : DAC_AD5781_intf.vhd
-- Author        : Thomas Chiesa tchiesa@bnl.gov
-- Created       : 07/19/2020
-------------------------------------------------------------------------------
-- Description:
-- This is the SPI controller for the AD5781 DAC. It accepts the 
-- DAC control bits for uni-polar and bi-polar control. Gains and offsets
-- can be applied. 
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-- Modification history:
-- 07/19/2020: created.
-- 08/19/2020: Changed program to send Control Register and Setpoint every cycle
-- 09/16/2020: Fixed Issue with bin2sc register, last bit of control register was not shifting out
-- 11/18/2026: writre DAC configuration one time and hard code the DAC config bits
-------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL; 

entity dac_ad5781 is
generic(
    SPI_CLK_DIV      : natural := 5;
    --BOOT_DELAY_CYCLES : natural := 10000000 -- 100 ms at 100 MHz after FPGA reset release
    BOOT_DELAY_CYCLES : natural := 10000 -- 100 ms at 100 MHz after FPGA reset release
); 
port(
        --Control inputs
        clk       : in std_logic; 
        reset     : in std_logic; 
        start     : in std_logic; 
        --DAC Inputs
        dac_data  : in std_logic_vector(19 downto 0); 
        dac_ctrl_bits : in std_logic_vector(4 downto 0);  
        --DAC Outputs
        n_sync    : out std_logic; 
        sclk      : out std_logic; 
        sdo       : out std_logic;
        done      : out std_logic
       );
end entity;

architecture arch of dac_ad5781 is
type state is (IDLE,SEND_CTRL_REG, SEND_SETPOINT, N_SYNC_ZERO,FIRST_BIT,SCLK_LO,SCLK_HI,DAC_DONE, WAIT_SYNC_LOW, WAIT_RESET_RECOVERY); 

constant SYNC_WIDTH    : natural := 10; --40ns is the minimum n_sync high time, 9 clocks is 90ns
constant BITS          : natural := 24; 
constant r_w           : std_logic := '0'; 
constant ctrl_reg_addr : std_logic_vector(2 downto 0) := "010"; 
constant dac_reg_addr  : std_logic_vector(2 downto 0) := "001"; 
constant reserved      : std_logic_vector(10 downto 0) := (others => '0'); 
constant lin_comp      : std_logic_vector(3 downto 0) := (others => '0'); 


signal present_state : state; 
signal bin2sc_reg  : std_logic; 
signal data_in_reg : std_logic_vector(19 downto 0); 
signal shift_reg   : std_logic_vector(23 downto 0); 
signal bit_count : natural range 0 to 25; 
signal clk_count : natural range 0 to 1000; 
signal sdo_dis_reg   : std_logic; 
signal rbuf_reg      : std_logic; 
signal dac_tri_reg   : std_logic; 
signal op_gnd_reg    : std_logic; 
signal init_count    : natural range 0 to 5;  
signal setpoint_sent : std_logic := '0';
-- Wait 100 ms after FPGA reset; send control register once after reset recovery.
signal boot_delay_count : natural range 0 to BOOT_DELAY_CYCLES := 0;
signal config_sent      : std_logic := '0';

signal config_in_progress : std_logic := '0';
constant RESET_RECOVERY_CYCLES : natural := 5000; -- 50 us at 100 MHz
signal reset_recovery_count : natural range 0 to RESET_RECOVERY_CYCLES := 0;
-- HARDWARE SANITY TEST ONLY: for bipolar +/-5 V, two's complement,
-- 0x0147B corresponds to approximately +100 mV.
-- Force each DAC setpoint to this code to avoid EPICS overwriting the test.
constant SANITY_DAC_CODE : std_logic_vector(19 downto 0) := x"0147B";


attribute mark_debug : string; 
attribute keep : string; 
attribute mark_debug of init_count : signal is "true"; 
attribute mark_debug of config_sent : signal is "true";
--attribute mark_debug of n_sync : signal is "true"; 
--attribute mark_debug of sclk : signal is "true"; 
--attribute mark_debug of sdo : signal is "true"; 
--attribute mark_debug of bin2sc_reg : signal is "true"; 
--attribute mark_debug of rbuf_reg : signal is "true"; 
attribute mark_debug of setpoint_sent : signal is "true"; 
--attribute mark_debug of bit_count : signal is "true"; 
attribute mark_debug of present_state : signal is "true"; 

begin

sdo <= shift_reg(23); 

process(clk)
begin 
    if rising_edge(clk) then 
        if reset = '1' then 
            data_in_reg     <= (others => '0'); 
        else 
            data_in_reg <= dac_data; 
            bin2sc_reg  <= '0'; -- Two's complement
            rbuf_reg    <= '0'; -- Preserve existing default
            dac_tri_reg <= '0'; -- Normal output
            sdo_dis_reg <= '0'; -- SDO enabled
            op_gnd_reg  <= '0'; -- Ground clamp removed
        end if; 
    end if; 
end process; 

process(clk) 
begin
    if rising_edge(clk) then 
        if reset = '1' then 
            present_state <= IDLE; 
            done <= '0'; -- clear completion flag on reset
            init_count <= 0;
            boot_delay_count <= 0;
            config_sent <= '0'; 
            sclk     <= '0'; 
            bit_count <= 0; 
            clk_count   <= 0; 
			setpoint_sent <= '0'; 
			n_sync <= '1';
			shift_reg <= (others => '0');
			config_in_progress <= '0';
            reset_recovery_count <= 0;
        else    
            if boot_delay_count < BOOT_DELAY_CYCLES then
                boot_delay_count <= boot_delay_count + 1;
            end if;
            case(present_state) is 
            
            --IDLE: Wait for start bit and determine if intial ctrl register needs to be sent to DAC.
            when IDLE => 
                done   <= '0'; 
                if start = '1' and boot_delay_count = BOOT_DELAY_CYCLES then 
                --sclk   <= '0'; 
                n_sync   <= '1'; 
                    if init_count = 0 then     --Software Control Register Set RESET bit (internal reset)
                        shift_reg     <= x"400004"; 
                        present_state <= N_SYNC_ZERO;
                    elsif init_count = 1 then  --Software Control Register Clear RESET bit (internal reset)
                        shift_reg     <= x"400000"; 
                        present_state <= N_SYNC_ZERO;
                    elsif config_sent = '0' then -- Configuration normally follows reset-clear recovery
                        present_state <= SEND_CTRL_REG;
                    else
                        present_state <= SEND_SETPOINT; 
                    end if; 
                end if; 
            -- Load the one-time control register word.
				
				when SEND_CTRL_REG =>
                    config_in_progress <= '1';
                    shift_reg <= r_w & ctrl_reg_addr &
                    reserved(9 downto 0) & lin_comp &
                    sdo_dis_reg & bin2sc_reg &
                    dac_tri_reg & op_gnd_reg &
                    rbuf_reg & reserved(0);
                    setpoint_sent <= '0';
                    present_state <= N_SYNC_ZERO;
			
			--SEND_SETPOINT: Load setpoint data to shift register
			when SEND_SETPOINT =>
                setpoint_sent <= '1';
                shift_reg <= r_w & dac_reg_addr & data_in_reg;
                present_state <= N_SYNC_ZERO;
			
            --N_SYNC_ZERO: Sync goes to zero, generic SYNC_WIDTH controls the time before SCLK goes high
            when N_SYNC_ZERO =>
                if clk_count = SYNC_WIDTH then 
                    n_sync <= '0'; 
                    clk_count <= 0; 
                    sclk      <= '1';
                    present_state <= FIRST_BIT;
                else 
                    n_sync    <= '1';
                    clk_count <= clk_count +1; 
                end if; 
                
            --FIRST_BIT: The first bit, bit 23 is shifted out on the rising edge of the of the first sclk pulse    
            when FIRST_BIT => 
                if clk_count = SPI_CLK_DIV -1 then 
                    sclk <= '0'; 
                    clk_count <= 0; 
                    bit_count <= bit_count +1;
                    present_state <= SCLK_LO; 
                else 
                    sclk <= '1'; 
                    clk_count <= clk_count +1; 
                end if; 
            
            --SCLK_HI: The high portion of the clock divider
            when SCLK_HI =>                 
                if clk_count = SPI_CLK_DIV -1 then 
                    if bit_count = (BITS) then  
                    --if bit_count = BITS then 
						if init_count = 2 then 
                            init_count <= 2; 
                        else                           
                            init_count <= init_count +1; 
                        end if;
                        bit_count <= 0; 
                        present_state <= DAC_DONE; 
                    else 
                        sclk <= '0';
                        bit_count   <= bit_count +1; 
                        present_state <= SCLK_LO; 
                    end if;   
                    clk_count <= 0;                    
                else 
                    sclk <= '1'; 
                    clk_count <= clk_count +1; 
                end if; 
              
           --SCLK_LO: The low portion of the clock divider  
           when SCLK_LO =>                 
                if clk_count = SPI_CLK_DIV -1 then 
                    sclk <= '1'; 
                    clk_count <= 0; 
                    shift_reg <= shift_reg(22 downto 0) & '0'; 
                    present_state <= SCLK_HI; 
                else 
                    sclk <= '0'; 
                    clk_count <= clk_count +1;                 
                end if; 
            -- Finish each SPI frame and select the next operation.
            when DAC_DONE =>
                if clk_count = SYNC_WIDTH - 1 then
                    clk_count <= 0;
                    n_sync <= '1';

                    if init_count = 1 then
                        -- 400004 software-reset frame has completed.
                        present_state <= IDLE;
                    elsif init_count = 2 and config_sent = '0' and
                          config_in_progress = '0' then
                        -- 400000 reset-clear frame has completed.
                        -- Start a 50 us quiet interval before configuration.
                        reset_recovery_count <= 0;
                        present_state <= WAIT_RESET_RECOVERY;
                    elsif config_in_progress = '1' then
                        -- 200000 control register frame completed.
                        config_in_progress <= '0';
                        config_sent <= '1';
                        present_state <= SEND_SETPOINT;
                    else
                        -- One fixed sanity setpoint completed.
                        done <= '1';
                        present_state <= WAIT_SYNC_LOW;
                    end if;
                else
                    n_sync <= '1';
                    clk_count <= clk_count + 1;
                end if;

            when WAIT_RESET_RECOVERY =>
                -- Keep SYNC high and SCLK idle while AD5781 recovers.
                n_sync <= '1';
                sclk <= '0';
                if reset_recovery_count = RESET_RECOVERY_CYCLES - 1 then
                    reset_recovery_count <= 0;
                    -- Send control configuration immediately; no start needed.
                    present_state <= SEND_CTRL_REG;
                else
                    reset_recovery_count <= reset_recovery_count + 1;
                end if;

    when WAIT_SYNC_LOW =>
        n_sync <= '1';  -- Keep SYNC HIGH between SPI frames

        if clk_count = SYNC_WIDTH - 1 then
            clk_count <= 0;
            present_state <= IDLE;
        else
        clk_count <= clk_count + 1;
    end if;
                
                 
                
            when others => 
                present_state <= IDLE; 
                
           end case; 
        end if; 
    end if; 
end process; 
end architecture;

